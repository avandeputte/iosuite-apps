import SwiftUI

/// One suggestion under the search field: what it finds, and the filter it adds.
struct SearchSuggestion: Identifiable {
    let id: String
    let label: String
    var sub: String? = nil
    let kind: String
    var symbol = "magnifyingglass"
    var face: Int? = nil
    let apply: (PhotoQuery) -> PhotoQuery
}

enum BulkSearch {
    private static func norm(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
    }

    /// The suggestions the web app's search box gives for this text: a text search, then years and months, detected
    /// content, people, tags, folders, albums, cameras, lenses, photographers, places and a few filters by name.
    @MainActor
    static func suggestions(_ text: String, current: PhotoQuery, catalog: BulkCatalog) -> [SearchSuggestion] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let words = norm(trimmed).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var out: [SearchSuggestion] = [
            SearchSuggestion(id: "q", label: "Search everything for “\(trimmed)”", kind: "Text") { $0.adding("q", trimmed) },
        ]
        if catalog.semantic {
            out.append(SearchSuggestion(id: "sem", label: "Photos that look like “\(trimmed)”", kind: "Content", symbol: "sparkles") {
                $0.setting("like", nil).setting("sem", trimmed)
            })
        }
        func score(_ name: String) -> Int {
            let n = norm(name)
            guard words.allSatisfy({ n.contains($0) }) else { return -1 }
            if n.hasPrefix(words[0]) { return 3 }
            if let r = n.range(of: words[0]), r.lowerBound > n.startIndex, !n[n.index(before: r.lowerBound)].isLetter && !n[n.index(before: r.lowerBound)].isNumber { return 2 }
            return 1
        }
        func top<T>(_ list: [T], _ limit: Int, name: (T) -> String, count: (T) -> Int) -> [T] {
            list.map { (score(name($0)), $0) }.filter { $0.0 > 0 }
                .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : count($0.1) > count($1.1) }
                .prefix(limit).map(\.1)
        }
        if trimmed.range(of: #"^(19|20)\d\d$"#, options: .regularExpression) != nil {
            out.append(SearchSuggestion(id: "year", label: trimmed, kind: "Year", symbol: "calendar") { $0.setting("year", trimmed) })
        }
        let months = Calendar(identifier: .gregorian).monthSymbols
        let parts = trimmed.split(separator: " ")
        if let first = parts.first, first.count >= 3, first.allSatisfy(\.isLetter),
           let mi = months.firstIndex(where: { $0.lowercased().hasPrefix(first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }) {
            let year = parts.count == 2 && parts[1].range(of: #"^(19|20)\d\d$"#, options: .regularExpression) != nil ? String(parts[1]) : nil
            if parts.count == 1 || year != nil {
                out.append(SearchSuggestion(id: "month", label: months[mi] + (year.map { " \($0)" } ?? ""), kind: "Month", symbol: "calendar") { q in
                    var q = q.setting("month", String(mi + 1))
                    if let year { q = q.setting("year", year) }
                    return q
                })
            }
        }
        for c in top(catalog.concepts, 3, name: \.0, count: \.1) {
            out.append(SearchSuggestion(id: "con\(c.0)", label: c.0, kind: "Detected · \(c.1.formatted())", symbol: "sparkles") { $0.setting("concept", c.0) })
        }
        let used = Set(current.values("tag"))
        let tags = catalog.tags.filter { $0.all > 0 && !used.contains(String($0.id)) }
        for t in top(tags.filter(\.person), 6, name: \.name, count: \.all) {
            out.append(SearchSuggestion(id: "p\(t.id)", label: t.name, sub: t.all.formatted(), kind: "Person", symbol: "person.crop.circle", face: t.id) {
                $0.adding("tag", String(t.id))
            })
        }
        for t in top(tags.filter { !$0.person }, 6, name: \.name, count: \.all) {
            let parent = t.full.contains("/") ? t.full.split(separator: "/").dropLast().joined(separator: " › ") : nil
            out.append(SearchSuggestion(id: "t\(t.id)", label: t.name, sub: parent, kind: "Tag · \(t.all.formatted())", symbol: "tag") {
                $0.adding("tag", String(t.id))
            })
        }
        for f in top(catalog.folders.filter { $0.pid != nil }, 5, name: \.name, count: \.all) {
            out.append(SearchSuggestion(id: "f\(f.id)", label: f.name, sub: f.path, kind: "Folder · \(f.all.formatted())", symbol: "folder") {
                $0.setting("album", nil).adding("album", String(f.id))
            })
        }
        for a in top(catalog.albums, 3, name: \.name, count: \.count) {
            out.append(SearchSuggestion(id: "ua\(a.id)", label: a.name, kind: "Album · \(a.count.formatted())", symbol: "rectangle.stack") {
                $0.setting("ualbum", String(a.id))
            })
        }
        for (kind, key, list, symbol) in [("Camera", "camera", catalog.cameras, "camera"), ("Lens", "lens", catalog.lenses, "camera.aperture"),
                                          ("Creator", "creator", catalog.creators, "c.circle")] {
            for c in top(list, 3, name: \.0, count: \.1) {
                out.append(SearchSuggestion(id: "\(key)\(c.0)", label: c.0, kind: "\(kind) · \(c.1.formatted())", symbol: symbol) { $0.adding(key, c.0) })
            }
        }
        for p in top(placeRows(catalog), 5, name: \.name, count: \.n) {
            out.append(SearchSuggestion(id: "pl\(p.key)\(p.name)", label: p.name, sub: p.sub, kind: "Place · \(p.n.formatted())", symbol: "mappin.and.ellipse") {
                $0.setting(p.key, p.name)
            })
        }
        if words.count == 1 {
            let w = words[0]
            if "favorites".hasPrefix(w) { out.append(SearchSuggestion(id: "fav", label: "Favorites", kind: "Filter", symbol: "heart") { $0.setting("fav", "1") }) }
            if "videos".hasPrefix(w) { out.append(SearchSuggestion(id: "vid", label: "Videos", kind: "Type", symbol: "video") { $0.setting("type", "video") }) }
            if "untagged".hasPrefix(w) { out.append(SearchSuggestion(id: "unt", label: "Untagged", kind: "Filter", symbol: "tag.slash") { $0.setting("untagged", "1") }) }
        }
        return out
    }

    /// Towns, regions and countries, each with how many photos (as the web app's place rows).
    @MainActor
    private static func placeRows(_ catalog: BulkCatalog) -> [(key: String, name: String, sub: String?, n: Int)] {
        var regions: [String: (String?, Int)] = [:], countries: [String: Int] = [:]
        var out: [(String, String, String?, Int)] = []
        for p in catalog.places {
            out.append(("place", p.city, [p.region, p.country].compactMap { $0 }.joined(separator: ", "), p.count))
            if let r = p.region { regions[r, default: (p.country, 0)].1 += p.count }
            if let c = p.country { countries[c, default: 0] += p.count }
        }
        out += regions.map { ("region", $0.key, $0.value.0, $0.value.1) }
        out += countries.map { ("country", $0.key, nil, $0.value) }
        return out
    }
}

/// The suggestion rows for `.searchSuggestions`: picking one adds its filter and clears the text.
struct SearchSuggestionRows: View {
    @Binding var text: String
    @Binding var query: PhotoQuery
    @ObservedObject private var catalog = BulkCatalog.shared

    var body: some View {
        ForEach(BulkSearch.suggestions(text, current: query, catalog: catalog)) { s in
            Button {
                query = s.apply(query)
                text = ""
            } label: {
                HStack(spacing: 10) {
                    if let f = s.face {
                        RemoteImage(path: "face/\(f)?v=\(catalog.tagByID[f]?.icon ?? 0)").frame(width: 28, height: 28).clipShape(Circle())
                    } else {
                        Image(systemName: s.symbol).frame(width: 28).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.label).foregroundStyle(.primary).lineLimit(1)
                        if let sub = s.sub, !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    Text(s.kind).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Saved searches (smart albums that update themselves): open one, save the current filters as one, rename or
/// delete them.
struct SavedSearchesMenu: View {
    @Binding var query: PhotoQuery
    @ObservedObject private var catalog = BulkCatalog.shared
    @State private var naming = false
    @State private var name = ""
    @State private var managing = false
    @State private var problem: String?

    private var saved: BulkCatalog.Search? { catalog.searches.first { PhotoQuery.saved($0.query).key == query.key } }

    var body: some View {
        Menu {
            if !catalog.searches.isEmpty {
                Section("Saved searches") {
                    ForEach(catalog.searches) { s in
                        Button {
                            let sort = query.value("sort")
                            query = PhotoQuery.saved(s.query).setting("sort", sort)
                        } label: {
                            Label(s.name, systemImage: s.id == saved?.id ? "checkmark" : "magnifyingglass")
                        }
                    }
                }
            }
            if catalog.canWrite && !query.filters.isEmpty && saved == nil {
                Button { name = ""; naming = true } label: { Label("Save this search…", systemImage: "plus") }
            }
            if catalog.canWrite && !catalog.searches.isEmpty {
                Button { managing = true } label: { Label("Rename or delete…", systemImage: "pencil") }
            }
            if catalog.searches.isEmpty && (!catalog.canWrite || query.filters.isEmpty) {
                Text("No saved searches yet")
            }
        } label: {
            Image(systemName: saved == nil ? "bookmark" : "bookmark.fill")
        }
        .accessibilityLabel("Saved searches")
        .task { await catalog.load() }
        .alert("Save this search", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await save() } }
        } message: { Text("It shows under Albums and updates itself as photos are added.") }
        .alert("Couldn't change the saved searches", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
        .sheet(isPresented: $managing) { SavedSearchesSheet() }
    }

    private func save() async {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        do {
            try await BulkAPI.post("api/searches", ["name": n, "query": query.queryString])
            await catalog.loadState()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Rename or delete saved searches.
struct SavedSearchesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = BulkCatalog.shared
    @State private var renaming: BulkCatalog.Search?
    @State private var name = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(catalog.searches) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name)
                        Text(catalog.chips(PhotoQuery.saved(s.query)).map(\.label).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .swipeActions {
                        Button(role: .destructive) { Task { await change(s, ["delete": true]) } } label: { Label("Delete", systemImage: "trash") }
                        Button { name = s.name; renaming = s } label: { Label("Rename", systemImage: "pencil") }.tint(.blue)
                    }
                    .contextMenu {
                        Button { name = s.name; renaming = s } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { Task { await change(s, ["delete": true]) } } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                if catalog.searches.isEmpty { Text("No saved searches.").foregroundStyle(.secondary) }
            }
            .navigationTitle("Saved searches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    if let s = renaming, !n.isEmpty, n != s.name { Task { await change(s, ["name": n]) } }
                }
            }
            .alert("Couldn't change it", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(problem ?? "") }
        }
    }

    private func change(_ s: BulkCatalog.Search, _ body: [String: Any]) async {
        do {
            try await BulkAPI.post("api/searches/\(s.id)", body)
            await catalog.loadState()
        } catch {
            problem = error.localizedDescription
        }
    }
}
