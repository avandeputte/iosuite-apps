import PhotosUI
import SwiftUI

/// One recipe, to cook from: its photos, the amounts for the servings wanted, ingredients to tick off, steps to strike
/// out; one's favourite and rating; and for who may, changing it.
struct RecipeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: Int

    @State private var recipe: Recipe?
    @State private var missing: String?
    @State private var factor = 1.0
    @State private var have: Set<Int> = []
    @State private var done: Set<Int> = []
    @State private var editing = false
    @State private var deleting = false
    @State private var viewing: Recipe.Photo?
    @State private var busy = false
    /// Where the next picture goes: nil the recipe's own, else that step.
    @State private var photoStep: Int?
    @State private var pickingPhoto = false
    @State private var picked: PhotosPickerItem?
    @State private var takingPhoto = false

    var body: some View {
        Group {
            if let r = recipe {
                content(r)
            } else if let missing {
                ContentUnavailableView("This recipe cannot be shown", systemImage: "fork.knife", description: Text(missing))
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if let r = recipe { toolbar(r) } }
        .task { await load() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = model.keepAwake }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(isPresented: $editing) {
            RecipeEditor(recipe: recipe, draft: nil) { recipe = $0 }
        }
        .fullScreenCover(item: $viewing) { PhotoViewer(photo: $0) }
        .photosPicker(isPresented: $pickingPhoto, selection: $picked, matching: .images)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { await add(image) }
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in Task { await add(image) } }.ignoresSafeArea()
        }
        .confirmationDialog("Delete this recipe?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { remove() }
        } message: {
            Text("“\(recipe?.title ?? "")” and its photos go for good.")
        }
    }

    // MARK: the page

    private func content(_ r: Recipe) -> some View {
        let own = (r.photos ?? []).filter { $0.step == nil }
        let ingredients = r.ingredients ?? []
        let comma = Amounts.usesComma(ingredients)
        let shown = ingredients.map { Amounts.isHeading($0) ? $0 : Amounts.scale($0, by: factor, comma: comma) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !own.isEmpty { pager(r, own) }
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(r.title).font(.title.bold())
                        if let d = r.description, !d.isEmpty { Text(d).foregroundStyle(.secondary) }
                        if !r.family { Label("Only you see this recipe", systemImage: "lock.fill").font(.footnote).foregroundStyle(.secondary) }
                    }
                    facts(r, comma: comma)
                    stars(r)
                    if !r.tags.isEmpty { tags(r) }
                    Divider()
                    ingredientList(r, shown)
                    Divider()
                    stepList(r)
                    if let n = r.notes, !n.isEmpty {
                        Divider()
                        Text("Notes").font(.title3.bold())
                        Text(n).textSelection(.enabled)
                    }
                    source(r)
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 30)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await load(fresh: true) }
        .overlay { if busy { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
    }

    private func pager(_ r: Recipe, _ own: [Recipe.Photo]) -> some View {
        TabView {
            ForEach(own) { p in
                Color.clear
                    .overlay { PhotoView(path: p.url) }
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { viewing = p }
                    .contextMenu {
                        if r.writable {
                            if p.id != own.first?.id {
                                Button { reorder(r, first: p, own) } label: { Label("Show this one on the card", systemImage: "rectangle.stack") }
                            }
                            Button(role: .destructive) { change { try await $0.deletePhoto(r.id, photo: p.id) } } label: {
                                Label("Delete photo", systemImage: "trash")
                            }
                        }
                    }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: own.count > 1 ? .always : .never))
        .frame(height: 280)
    }

    private func facts(_ r: Recipe, comma: Bool) -> some View {
        HStack(alignment: .top, spacing: 22) {
            if let m = r.prepMinutes, m > 0 { fact("Preparation", Recipe.minutes(m)) }
            if let m = r.cookMinutes, m > 0 { fact("Cooking", Recipe.minutes(m)) }
            if let m = r.totalMinutes, m > 0 { fact("Total", Recipe.minutes(m)) }
            if let s = r.servings, !s.isEmpty {
                fact(factor == 1 ? "Makes" : "Makes (\(Amounts.name(factor)))",
                     s.contains(where: \.isNumber) ? Amounts.scale(s, by: factor, comma: comma) : s)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold))
        }
    }

    private func stars(_ r: Recipe) -> some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { n in
                Button {
                    change { try await $0.setRating(r.id, r.rating == n ? nil : n) }
                } label: {
                    Image(systemName: (r.rating ?? 0) >= n ? "star.fill" : "star").font(.title3)
                        .foregroundStyle((r.rating ?? 0) >= n ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(n) star\(n == 1 ? "" : "s")")
            }
            if let avg = r.ratingAverage {
                Text(String(format: "%.1f", avg) + " from \(r.ratingCount)").font(.footnote).foregroundStyle(.secondary).padding(.leading, 6)
            }
        }
    }

    private func tags(_ r: Recipe) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(r.tags, id: \.self) { t in
                    Button(t) {
                        model.filter = Filter(tag: t)
                        dismiss()
                    }
                    .font(.footnote).buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
            }
        }
    }

    private func ingredientList(_ r: Recipe, _ shown: [String]) -> some View {
        let scalable = (r.ingredients ?? []).contains { !Amounts.isHeading($0) && Amounts.hasAmount($0) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ingredients").font(.title3.bold())
                Spacer()
                if scalable {
                    HStack(spacing: 2) {
                        Button { step(-1) } label: { Image(systemName: "minus.circle") }
                            .disabled(factor <= Amounts.factors.first!).accessibilityLabel("Less")
                        Text(Amounts.name(factor)).font(.subheadline.monospacedDigit().weight(factor == 1 ? .regular : .semibold))
                            .foregroundStyle(factor == 1 ? Color.secondary : Color.accentColor).frame(minWidth: 48)
                        Button { step(1) } label: { Image(systemName: "plus.circle") }
                            .disabled(factor >= Amounts.factors.last!).accessibilityLabel("More")
                    }
                    .font(.title3)
                }
            }
            if factor != 1 { Button("As written") { factor = 1 }.font(.footnote) }
            if shown.isEmpty { Text("None listed.").foregroundStyle(.secondary) }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, line in
                if Amounts.isHeading(line) {
                    Text(line.dropLast()).font(.headline).padding(.top, 6)
                } else {
                    Button {
                        if have.contains(i) { have.remove(i) } else { have.insert(i) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: have.contains(i) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(have.contains(i) ? Color.accentColor : Color.secondary)
                            Text(line).foregroundStyle(have.contains(i) ? .secondary : .primary).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func stepList(_ r: Recipe) -> some View {
        let steps = r.steps ?? []
        let pictures = Dictionary((r.photos ?? []).compactMap { p in p.step.map { ($0, p) } }, uniquingKeysWith: { a, _ in a })
        var number = 0
        let numbers: [Int?] = steps.map { line in
            if Amounts.isHeading(line) { return nil }
            number += 1
            return number
        }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Steps").font(.title3.bold())
            if steps.isEmpty { Text("None written.").foregroundStyle(.secondary) }
            ForEach(Array(steps.enumerated()), id: \.offset) { i, line in
                if let n = numbers[i] {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(n)").font(.headline.monospacedDigit()).foregroundStyle(done.contains(i) ? Color.secondary : Color.accentColor)
                                .frame(minWidth: 22, alignment: .trailing)
                            Text(line).strikethrough(done.contains(i)).foregroundStyle(done.contains(i) ? .secondary : .primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if done.contains(i) { done.remove(i) } else { done.insert(i) } }
                        if let p = pictures[i] {
                            Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .overlay { PhotoView(path: p.url) }
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .padding(.leading, 32)
                                .onTapGesture { viewing = p }
                        }
                    }
                    .contextMenu {
                        if r.writable {
                            Button { photoStep = i; pickingPhoto = true } label: { Label(pictures[i] == nil ? "Add a picture of this step" : "Replace its picture", systemImage: "photo") }
                            if CameraPicker.available {
                                Button { photoStep = i; takingPhoto = true } label: { Label("Take a picture of this step", systemImage: "camera") }
                            }
                            if let p = pictures[i] {
                                Button(role: .destructive) { change { try await $0.deletePhoto(r.id, photo: p.id) } } label: { Label("Remove its picture", systemImage: "trash") }
                            }
                        }
                    }
                } else {
                    Text(line.dropLast()).font(.headline).padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func source(_ r: Recipe) -> some View {
        let name = r.sourceName ?? ""
        if let s = r.sourceUrl, let url = URL(string: s), url.scheme?.hasPrefix("http") == true {
            Link(destination: url) { Label(name.isEmpty ? (url.host ?? s) : name, systemImage: "link") }.font(.footnote)
        } else if !name.isEmpty {
            Label("From \(name)", systemImage: "book.closed").font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: the bar

    @ToolbarContentBuilder
    private func toolbar(_ r: Recipe) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                change { try await $0.setFavourite(r.id, !r.favourite) }
            } label: {
                Image(systemName: r.favourite ? "heart.fill" : "heart")
            }
            .accessibilityLabel(r.favourite ? "Not a favourite" : "A favourite")
            Menu {
                ShareLink(item: shopping(r)) { Label("Share ingredients", systemImage: "cart") }
                let books = model.books.filter { $0.writable && (!$0.family || r.family) }
                if !books.isEmpty {
                    Menu {
                        ForEach(books) { b in
                            let inside = (r.books ?? []).contains(b.id)
                            Button { toggle(b, r, inside) } label: {
                                if inside { Label(b.name, systemImage: "checkmark") } else { Text(b.name) }
                            }
                        }
                    } label: {
                        Label("Cookbooks", systemImage: "books.vertical")
                    }
                }
                if r.writable {
                    Section {
                        Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                        Button { photoStep = nil; pickingPhoto = true } label: { Label("Add a photo", systemImage: "photo") }
                        if CameraPicker.available {
                            Button { photoStep = nil; takingPhoto = true } label: { Label("Take a photo", systemImage: "camera") }
                        }
                    }
                    Section {
                        Button(role: .destructive) { deleting = true } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    /// The ingredients still to get (those ticked off are in the house), for the servings shown: for a shopping list.
    private func shopping(_ r: Recipe) -> String {
        let all = r.ingredients ?? []
        let comma = Amounts.usesComma(all)
        let lines = all.enumerated().filter { !have.contains($0.offset) && !Amounts.isHeading($0.element) }
            .map { Amounts.scale($0.element, by: factor, comma: comma) }
        return ([r.title + (factor == 1 ? "" : " (\(Amounts.name(factor)))")] + lines).joined(separator: "\n")
    }

    // MARK: doing

    private func step(_ d: Int) {
        let at = Amounts.factors.firstIndex { abs($0 - factor) < 0.01 } ?? 5
        factor = Amounts.factors[max(0, min(Amounts.factors.count - 1, at + d))]
    }

    private func load(fresh: Bool = false) async {
        if recipe == nil, let kept: Recipe = Cache.read("recipe-\(id)") { recipe = kept }
        guard let api = model.api else { return }
        do {
            let r = try await api.recipe(id)
            recipe = r
            model.changed(r)
        } catch {
            if recipe == nil {
                if case APIError.signedOut = error { model.failed(error) } else { missing = error.localizedDescription }
            } else {
                model.failed(error, quiet: !fresh)
            }
        }
    }

    /// A change the server answers with the recipe as it is now.
    private func change(_ work: @escaping (API) async throws -> Recipe) {
        guard let api = model.api else { return }
        Task {
            do {
                let r = try await work(api)
                recipe = r
                model.changed(r)
            } catch {
                model.failed(error)
            }
        }
    }

    private func add(_ image: UIImage) async {
        guard let api = model.api, let jpeg = image.jpeg() else { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await api.addPhoto(id, jpeg: jpeg, step: photoStep)
            recipe = r
            model.changed(r)
        } catch {
            model.failed(error)
        }
    }

    private func reorder(_ r: Recipe, first: Recipe.Photo, _ own: [Recipe.Photo]) {
        let ids = [first.id] + own.map(\.id).filter { $0 != first.id }
        change { try await $0.orderPhotos(r.id, ids: ids) }
    }

    private func toggle(_ b: Book, _ r: Recipe, _ inside: Bool) {
        change { api in
            if inside { try await api.takeFromBook(b.id, recipe: r.id) } else { try await api.putInBook(b.id, recipe: r.id) }
            return try await api.recipe(r.id)
        }
        Task { await model.refresh() }
    }

    private func remove() {
        guard let api = model.api else { return }
        Task {
            do {
                try await api.delete(id)
                await model.refresh()
                dismiss()
            } catch {
                model.failed(error)
            }
        }
    }
}

/// A picture, large, over the page: pinch to look closer.
struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let photo: Recipe.Photo
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            PhotoView(path: photo.url, fit: true)
                .scaleEffect(max(1, zoom * pinch))
                .gesture(MagnificationGesture().updating($pinch) { v, s, _ in s = v }.onEnded { zoom = max(1, min(5, zoom * $0)) })
                .onTapGesture(count: 2) { withAnimation { zoom = zoom > 1 ? 1 : 2.5 } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).symbolRenderingMode(.hierarchical).foregroundStyle(.white)
            }
            .padding()
            .accessibilityLabel("Close")
        }
    }
}
