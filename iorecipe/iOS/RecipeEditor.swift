import SwiftUI

/// The form of a recipe: a new one (empty, or from the draft an import left) or one to change.
struct RecipeEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let recipe: Recipe?
    let draft: Draft?
    let onSaved: (Recipe) -> Void

    @State private var title = ""
    @State private var description = ""
    @State private var servings = ""
    @State private var prep = ""
    @State private var cook = ""
    @State private var total = ""
    @State private var ingredients = ""
    @State private var steps = ""
    @State private var notes = ""
    @State private var tags = ""
    @State private var sourceUrl = ""
    @State private var sourceName = ""
    @State private var family = true
    @State private var filled = false
    @State private var working = false
    @State private var failure: String?

    /// Whether the recipe may be moved between the family's and one's own.
    private var mayMove: Bool { model.mayAddFamily && model.mayAddOwn }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Description", text: $description, axis: .vertical).lineLimit(1...4)
                }
                Section {
                    LabeledContent("Makes") { TextField("4, or 24 cookies", text: $servings).multilineTextAlignment(.trailing) }
                    minutes("Preparation", $prep)
                    minutes("Cooking", $cook)
                    minutes("Total, when it is more", $total)
                }
                Section {
                    TextEditor(text: $ingredients).frame(minHeight: 150)
                } header: {
                    Text("Ingredients")
                } footer: {
                    Text("One on each line. A line that ends with a colon (For the icing:) is a heading.")
                }
                Section {
                    TextEditor(text: $steps).frame(minHeight: 190)
                } header: {
                    Text("Steps")
                } footer: {
                    Text("One on each line.")
                }
                Section("Notes") {
                    TextEditor(text: $notes).frame(minHeight: 80)
                }
                Section {
                    TextField("Tags", text: $tags, prompt: Text("dinner, quick")).textInputAutocapitalization(.never)
                    TextField("From (a person, a book, a site)", text: $sourceName)
                    TextField("Its web address", text: $sourceUrl)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("Commas between tags.")
                }
                if mayMove {
                    Section { Toggle("A family recipe", isOn: $family) } footer: { Text(family ? "Everyone sees it." : "Only you see it.") }
                }
                if let failure { Section { Text(failure).foregroundStyle(.red).font(.callout) } }
            }
            .navigationTitle(recipe == nil ? "New recipe" : "Edit recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(working || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .interactiveDismissDisabled()
            .onAppear(perform: fill)
        }
    }

    private func minutes(_ label: String, _ value: Binding<String>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField("0", text: value).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 70)
                Text("min").foregroundStyle(.secondary)
            }
        }
    }

    private func fill() {
        guard !filled else { return }
        filled = true
        let d = draft ?? recipe.map {
            Draft(title: $0.title, description: $0.description, servings: $0.servings, prepMinutes: $0.prepMinutes,
                  cookMinutes: $0.cookMinutes, totalMinutes: nil, ingredients: $0.ingredients, steps: $0.steps, notes: $0.notes,
                  tags: $0.tags, sourceUrl: $0.sourceUrl, sourceName: $0.sourceName, family: $0.family)
        }
        family = d?.family ?? model.mayAddFamily
        guard let d else { return }
        title = d.title ?? ""
        description = d.description ?? ""
        servings = d.servings ?? ""
        prep = d.prepMinutes.map(String.init) ?? ""
        cook = d.cookMinutes.map(String.init) ?? ""
        // the server gives preparation plus cooking as the total when none was written: that one is not typed in
        if let r = recipe, let t = r.totalMinutes, t != (r.prepMinutes ?? 0) + (r.cookMinutes ?? 0) { total = String(t) }
        if recipe == nil, let t = d.totalMinutes { total = String(t) }
        ingredients = (d.ingredients ?? []).joined(separator: "\n")
        steps = (d.steps ?? []).joined(separator: "\n")
        notes = d.notes ?? ""
        tags = (d.tags ?? []).joined(separator: ", ")
        sourceUrl = d.sourceUrl ?? ""
        sourceName = d.sourceName ?? ""
    }

    private func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func save() {
        guard let api = model.api else { return }
        // every field is sent, an empty one as "" or 0, so that one cleared here is cleared on the server
        var body: [String: Any] = [
            "title": title, "description": description, "servings": servings,
            "prepMinutes": Int(prep) ?? 0, "cookMinutes": Int(cook) ?? 0, "totalMinutes": Int(total) ?? 0,
            "ingredients": lines(ingredients), "steps": lines(steps), "notes": notes,
            "tags": tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            "sourceUrl": sourceUrl.trimmingCharacters(in: .whitespaces), "sourceName": sourceName,
        ]
        if mayMove { body["family"] = family }
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                let saved: Recipe
                if let recipe {
                    saved = try await api.call("PATCH", "api/recipes/\(recipe.id)", json: body)
                } else {
                    saved = try await api.call("POST", "api/recipes", json: body)
                }
                model.changed(saved)
                await model.refresh()
                dismiss()
                onSaved(saved)
            } catch {
                if case APIError.signedOut = error { model.failed(error) } else { failure = error.localizedDescription }
            }
        }
    }
}
