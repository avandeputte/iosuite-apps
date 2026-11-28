import PhotosUI
import SwiftUI

/// The recipes as cards: all of them, the family's, one's own or the favourites, with a tag or in a cookbook, searched
/// and sorted; and the ways to add one.
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [Int] = []
    @State private var sheet: Sheet?
    @State private var pickingPhoto = false
    @State private var picked: PhotosPickerItem?
    @State private var takingPhoto = false
    @State private var reading = false
    @State private var readsPhotos = false

    enum Sheet: Identifiable {
        case editor(Draft?), web, text
        var id: String {
            switch self {
            case .editor: return "editor"
            case .web: return "web"
            case .text: return "text"
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 158, maximum: 260), spacing: 14, alignment: .top)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                Picker("Show", selection: $model.filter.scope) {
                    ForEach(Filter.Scope.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                if model.offline {
                    Label("No connection: showing what was kept on this device.", systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
                }
                if let chip = chip {
                    Button { model.filter.tag = nil; model.filter.book = nil } label: {
                        Label(chip, systemImage: "xmark.circle.fill").font(.subheadline)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).padding(.top, 6)
                }
                if model.loaded && model.recipes.isEmpty {
                    ContentUnavailableView(model.filter.search.isEmpty ? "No recipes here yet" : "No recipe found",
                                           systemImage: "fork.knife",
                                           description: Text(model.filter.search.isEmpty && model.mayAdd ? "Add one with +, or import it from a web page." : ""))
                        .padding(.top, 60)
                } else if !model.loaded {
                    ProgressView().padding(.top, 80)
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(model.recipes) { r in
                        NavigationLink(value: r.id) { RecipeCard(recipe: r) }
                            .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Recipes")
            .navigationDestination(for: Int.self) { RecipeView(id: $0) }
            .searchable(text: $model.filter.search, prompt: "Search recipes")
            .refreshable { await model.refresh(quiet: false) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    filterMenu
                    if model.mayAdd { addMenu }
                }
            }
        }
        .task(id: model.filter) {
            // typing in the search waits a moment before asking
            if !model.filter.search.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
            if !Task.isCancelled { await model.refresh() }
        }
        .task {
            if let ways = try? await model.api?.importWays() { readsPhotos = ways.photo }
        }
        .onChange(of: model.opening) { _, id in
            if let id {
                path = [id]
                model.opening = nil
            }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .editor(let draft): RecipeEditor(recipe: nil, draft: draft) { model.opening = $0.id }
            case .web: ImportWebView()
            case .text: ImportTextView { sheet = .editor($0) }
            }
        }
        .photosPicker(isPresented: $pickingPhoto, selection: $picked, matching: .images)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { await read(image) }
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in Task { await read(image) } }.ignoresSafeArea()
        }
        .overlay {
            if reading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Reading the photo…").font(.callout)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    /// The tag or the cookbook the list is narrowed to.
    private var chip: String? {
        if let tag = model.filter.tag { return tag }
        if let book = model.filter.book { return model.books.first { $0.id == book }?.name ?? "Cookbook" }
        return nil
    }

    private var filterMenu: some View {
        Menu {
            Picker("Order", selection: $model.filter.sort) {
                ForEach(Filter.Sort.allCases) { Text($0.label).tag($0) }
            }
            if !model.books.isEmpty {
                Menu("Cookbooks") {
                    ForEach(model.books) { b in
                        Button { model.filter.tag = nil; model.filter.book = model.filter.book == b.id ? nil : b.id } label: {
                            Label(b.count.map { "\(b.name) (\($0))" } ?? b.name, systemImage: model.filter.book == b.id ? "checkmark" : b.family ? "book" : "person")
                        }
                    }
                }
            }
            if !model.tags.isEmpty {
                Menu("Tags") {
                    ForEach(model.tags, id: \.tag) { t in
                        Button { model.filter.book = nil; model.filter.tag = model.filter.tag == t.tag ? nil : t.tag } label: {
                            if model.filter.tag == t.tag { Label("\(t.tag) (\(t.count))", systemImage: "checkmark") } else { Text("\(t.tag) (\(t.count))") }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: model.filter.tag != nil || model.filter.book != nil ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Order and filter")
    }

    private var addMenu: some View {
        Menu {
            Button { sheet = .editor(nil) } label: { Label("New recipe", systemImage: "square.and.pencil") }
            Section("Import") {
                Button { sheet = .web } label: { Label("From a web page", systemImage: "globe") }
                Button { sheet = .text } label: { Label("From pasted text", systemImage: "doc.on.clipboard") }
                if readsPhotos {
                    Button { pickingPhoto = true } label: { Label("From a photo", systemImage: "photo") }
                    if CameraPicker.available {
                        Button { takingPhoto = true } label: { Label("From the camera", systemImage: "camera") }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add a recipe")
    }

    /// The text on a photo of a recipe, read by the server into a draft that opens in the form.
    private func read(_ image: UIImage) async {
        guard let api = model.api, let jpeg = image.jpeg(side: 3000, quality: 0.9) else { return }
        reading = true
        defer { reading = false }
        do {
            sheet = .editor(try await api.draft(photo: jpeg))
        } catch {
            model.failed(error)
        }
    }
}

struct RecipeCard: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay { PhotoView(path: recipe.photo, small: true) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if recipe.favourite {
                        Image(systemName: "heart.fill").foregroundStyle(.white).padding(6)
                            .background(.black.opacity(0.35), in: Circle()).padding(6)
                    }
                }
            Text(recipe.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
            HStack(spacing: 4) {
                if let avg = recipe.ratingAverage {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    Text(String(format: "%.1f", avg))
                }
                Text(recipe.meta).lineLimit(1)
                if !recipe.family { Image(systemName: "lock.fill") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// Import › From a web page: the address of a recipe; the server fetches the page and keeps the recipe on it.
struct ImportWebView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var family = true
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address", text: $address, prompt: Text("https://…"))
                        .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if UIPasteboard.general.hasURLs {
                        Button("Paste") { address = UIPasteboard.general.url?.absoluteString ?? address }
                    }
                } footer: {
                    Text("The server fetches the page and keeps the recipe on it, with its picture and a link back. Some pages take a minute.")
                }
                if model.mayAddFamily && model.mayAddOwn {
                    Section { Toggle("A family recipe", isOn: $family) } footer: { Text(family ? "Everyone sees it." : "Only you see it.") }
                }
                Section {
                    Button(action: go) {
                        HStack {
                            if working { ProgressView() }
                            Text(working ? "Importing…" : "Import")
                        }
                    }
                    .disabled(working || address.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let failure { Text(failure).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle("From a web page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { family = model.mayAddFamily }
            .interactiveDismissDisabled(working)
        }
    }

    private func go() {
        guard let api = model.api else { return }
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                let r = try await api.importPage(address.trimmingCharacters(in: .whitespaces), family: model.mayAddFamily && model.mayAddOwn ? family : nil)
                await model.refresh()
                dismiss()
                model.opening = r.id
            } catch {
                if case APIError.signedOut = error { model.failed(error) } else { failure = error.localizedDescription }
            }
        }
    }
}

/// Import › From pasted text: the server makes a draft of it, which opens in the form to be looked over.
struct ImportTextView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onDraft: (Draft) -> Void
    @State private var text = ""
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text).frame(minHeight: 260)
                } footer: {
                    Text("Paste a recipe from a message, a document or a page. It opens in the form, for you to look over before it is saved.")
                }
                if let failure { Text(failure).foregroundStyle(.red).font(.callout) }
            }
            .navigationTitle("From pasted text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    if UIPasteboard.general.hasStrings { Button("Paste") { text = UIPasteboard.general.string ?? text } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") { go() }.disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func go() {
        guard let api = model.api else { return }
        working = true
        failure = nil
        Task {
            defer { working = false }
            do { onDraft(try await api.draft(text: text)) } catch {
                if case APIError.signedOut = error { model.failed(error) } else { failure = error.localizedDescription }
            }
        }
    }
}
