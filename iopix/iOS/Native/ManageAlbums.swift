import SwiftUI

/// Your albums in iopix (not digiKam's folders): shared ones everybody sees, private ones only you see.
@MainActor
final class AlbumList: ObservableObject {
    struct Item: Identifiable, Hashable {
        let id: Int
        var name: String
        let count: Int
        let cover: Int?
        var shared: Bool
        let mine: Bool
        let canEdit: Bool
    }
    /// A smart album: a saved search, run live for its count and cover.
    struct Smart: Identifiable, Hashable {
        let id: Int
        var name: String
        let query: String
    }
    @Published var albums: [Item] = []
    @Published var searches: [Smart] = []
    /// What each smart album finds now: how many photos, and the first one as its cover (nil while still running).
    @Published var smartCounts: [Int: (count: Int, cover: Int?)] = [:]
    @Published var canShare = false
    @Published var canPrivate = false
    @Published var loaded = false
    @Published var problem: String?

    func load() async {
        let st: [String: Any]
        do { st = try await ManageAPI.get("api/state"); problem = nil } catch { problem = error.localizedDescription; loaded = true; return }
        canShare = st["canShareAlbums"] as? Bool ?? false
        canPrivate = st["canPrivateAlbums"] as? Bool ?? false
        albums = (st["albums"] as? [[String: Any]] ?? []).compactMap { a in
            guard let id = (a["id"] as? NSNumber)?.intValue else { return nil }
            return Item(id: id, name: a["name"] as? String ?? "", count: (a["n"] as? NSNumber)?.intValue ?? 0,
                        cover: (a["cover"] as? NSNumber)?.intValue, shared: a["shared"] as? Bool ?? true,
                        mine: a["mine"] as? Bool ?? false, canEdit: a["canEdit"] as? Bool ?? false)
        }
        searches = (st["searches"] as? [[String: Any]] ?? []).compactMap { x in
            guard let id = (x["id"] as? NSNumber)?.intValue else { return nil }
            return Smart(id: id, name: x["name"] as? String ?? "", query: x["query"] as? String ?? "")
        }
        loaded = true
        await loadSmartCounts()
    }

    /// Runs each smart album's search once (the web app does the same, per library version) for its count and cover.
    private func loadSmartCounts() async {
        let list = searches
        await withTaskGroup(of: (Int, (count: Int, cover: Int?)?).self) { group in
            for s in list where smartCounts[s.id] == nil {
                group.addTask {
                    guard let l = try? await PhotoList.load(PhotoQuery.saved(s.query).items) else { return (s.id, nil) }
                    return (s.id, (l.ids.count, l.ids.first))
                }
            }
            for await (id, r) in group { if let r { smartCounts[id] = r } }
        }
    }
}

/// Favorites and your albums: make, rename, share or make private, delete; open one to see or remove its photos.
struct ManageAlbumsScreen: View {
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var list = AlbumList()
    @StateObject private var rights = ManageRights()
    @State private var filter = ""
    @State private var creating = false
    @State private var newName = ""
    @State private var newShared = true
    @State private var renaming: AlbumList.Item?
    @State private var renamingSmart: AlbumList.Smart?
    @State private var renameText = ""
    @State private var deleting: AlbumList.Item?
    @State private var deletingSmart: AlbumList.Smart?
    @State private var notice: Notice?

    private func matches(_ name: String) -> Bool {
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty || name.localizedStandardContains(f)
    }

    var body: some View {
        List {
            if filter.isEmpty {
                NavigationLink {
                    PhotoGridScreen(query: PhotoQuery([("fav", "1")]), title: "Favorites")
                } label: {
                    ThumbRow(cover: nil, title: "Favorites", sub: store.favorites.formatted(), symbol: "heart.fill")
                }
            }
            let albums = list.albums.filter { matches($0.name) }
            let shared = albums.filter(\.shared), mine = albums.filter { !$0.shared }
            let smart = list.searches.filter { matches($0.name) }
            if !shared.isEmpty { Section("Shared albums") { ForEach(shared) { row($0) } } }
            if !mine.isEmpty { Section("Only you") { ForEach(mine) { row($0) } } }
            if !smart.isEmpty || filter.isEmpty {
                Section {
                    ForEach(smart) { smartRow($0) }
                } header: { Text("Smart albums") } footer: {
                    Text(smart.isEmpty ? "None yet. Filter or search the photos, then choose “Save this search…” from the bookmark menu above the grid."
                         : "Smart albums are saved searches that update themselves.")
                }
            }
            if let problem = list.problem { Text(problem).foregroundStyle(.secondary) }
            if list.loaded && list.albums.isEmpty && list.problem == nil && filter.isEmpty {
                Text("No albums yet. Make one here, or select photos and choose Add to album.").font(.footnote).foregroundStyle(.secondary)
            }
            if !filter.isEmpty && albums.isEmpty && smart.isEmpty { Text("No albums match.").foregroundStyle(.secondary) }
        }
        .navigationTitle("Albums")
        .searchable(text: $filter, prompt: "Find an album")
        .toolbar {
            if list.canShare || list.canPrivate {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newName = ""; newShared = list.canShare; creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New album")
                }
            }
        }
        .task { await rights.load(); await list.load() }
        .refreshable { await list.load(); await store.load() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                Form {
                    TextField("Album name", text: $newName)
                    if list.canShare && list.canPrivate {
                        Toggle("Shared with everyone", isOn: $newShared)
                    }
                }
                .navigationTitle("New album")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button { creating = false } label: { CloseLabel("Cancel") } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            let n = newName.trimmingCharacters(in: .whitespaces)
                            creating = false
                            Task { await act("api/ualbums", ["name": n, "shared": list.canShare ? newShared : false], "Album “\(n)” made.") }
                        } label: { BarText("Create") }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .namePrompt("Rename album", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), text: $renameText) { name in
            if let a = renaming { Task { await act("api/ualbums/\(a.id)", ["name": name], "Renamed.") } }
        }
        .namePrompt("Rename smart album", isPresented: Binding(get: { renamingSmart != nil }, set: { if !$0 { renamingSmart = nil } }), text: $renameText) { name in
            if let s = renamingSmart { Task { await act("api/searches/\(s.id)", ["name": name], "Renamed.") } }
        }
        .confirmationDialog("Delete the smart album “\(deletingSmart?.name ?? "")”?", isPresented: Binding(get: { deletingSmart != nil }, set: { if !$0 { deletingSmart = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let s = deletingSmart { Task { await act("api/searches/\(s.id)", ["delete": true], "Smart album deleted.") } }
            }
        } message: { Text("The photos are not touched.") }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete album", role: .destructive) {
                if let a = deleting { Task { await act("api/ualbums/\(a.id)", ["delete": true], "Album deleted.") } }
            }
        } message: { Text("The photos stay in the library; only the album goes.") }
        .notice($notice)
    }

    private func row(_ a: AlbumList.Item) -> some View {
        NavigationLink {
            ManageAlbumDetail(album: a, list: list)
        } label: {
            ThumbRow(cover: a.cover, title: a.name, sub: a.count.formatted() + (a.shared ? "" : " · only you"), symbol: "rectangle.stack")
        }
        .swipeActions(edge: .trailing) {
            if a.canEdit {
                Button("Delete", role: .destructive) { deleting = a }
                Button("Rename") { renameText = a.name; renaming = a }.tint(Hue.blue)
            }
        }
        .contextMenu {
            Button {
                copyLink("ualbum=\(a.id)", a.shared ? "Link copied. It works for anyone who can reach iopix." : "Link copied. The album is private: it opens only for you.")
            } label: { Label("Copy link", systemImage: "link") }
            if a.canEdit {
                Button { renameText = a.name; renaming = a } label: { Label("Rename…", systemImage: "pencil") }
                if a.shared, list.canPrivate, a.mine || list.canShare {
                    Button { Task { await act("api/ualbums/\(a.id)", ["shared": false], "Only you see “\(a.name)” now.") } } label: {
                        Label("Make private", systemImage: "lock")
                    }
                } else if !a.shared, list.canShare {
                    Button { Task { await act("api/ualbums/\(a.id)", ["shared": true], "Everyone sees “\(a.name)” now.") } } label: {
                        Label("Share with everyone", systemImage: "person.2")
                    }
                }
                Button(role: .destructive) { deleting = a } label: { Label("Delete album…", systemImage: "trash") }
            }
        }
    }

    /// A smart album: its search, run live for the count and cover; open it, copy its link, rename or delete it.
    private func smartRow(_ s: AlbumList.Smart) -> some View {
        let r = list.smartCounts[s.id]
        return NavigationLink {
            PhotoGridScreen(query: PhotoQuery.saved(s.query), title: s.name)
        } label: {
            ThumbRow(cover: r?.cover, title: s.name, sub: r.map { ManageAPI.plural($0.count, "photo") } ?? "…", symbol: "magnifyingglass")
        }
        .swipeActions(edge: .trailing) {
            if rights.canWrite {
                Button("Delete", role: .destructive) { deletingSmart = s }
                Button("Rename") { renameText = s.name; renamingSmart = s }.tint(Hue.blue)
            }
        }
        .contextMenu {
            Button { copyLink(PhotoQuery.saved(s.query).queryString, "Link copied.") } label: { Label("Copy link", systemImage: "link") }
            if rights.canWrite {
                Button { renameText = s.name; renamingSmart = s } label: { Label("Rename…", systemImage: "pencil") }
                Button(role: .destructive) { deletingSmart = s } label: { Label("Delete smart album…", systemImage: "trash") }
            }
        }
    }

    /// The web app's address for these filters, on the clipboard.
    private func copyLink(_ query: String, _ said: String) {
        var origin = AppConfig.serverURL.absoluteString
        while origin.hasSuffix("/") { origin.removeLast() }
        UIPasteboard.general.string = origin + "/#/photos?" + query
        notice = Notice(text: said)
    }

    private func act(_ path: String, _ body: [String: Any], _ ok: String) async {
        do {
            _ = try await ManageAPI.post(path, body)
            notice = Notice(text: ok)
            await list.load()
            await store.load()
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }
}

/// One album's photos: see them full screen, or select some to take out of the album.
struct ManageAlbumDetail: View {
    let album: AlbumList.Item
    @ObservedObject var list: AlbumList
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var router: Router
    @State private var photos = PhotoList()
    @State private var loaded = false
    @State private var selecting = false
    @State private var selected: Set<Int> = []
    @State private var viewer: PagerStart?
    @State private var notice: Notice?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 3)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(Array(photos.ids.enumerated()), id: \.element) { i, id in
                    Button {
                        if selecting { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
                        else { viewer = PagerStart(list: photos, index: i) }
                    } label: {
                        RemoteImage(path: "thumb/\(id)").aspectRatio(1, contentMode: .fill).clipped()
                            .overlay(alignment: .bottomTrailing) {
                                if selecting {
                                    Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3).foregroundStyle(.white).shadow(radius: 2).padding(5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            if loaded && photos.ids.isEmpty {
                Text("This album is empty. Select photos anywhere and choose Add to album.").foregroundStyle(.secondary).padding(40)
            }
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if album.canEdit && !photos.ids.isEmpty {
                    Button(selecting ? "Done" : "Select") { selecting.toggle(); selected = [] }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack {
                    Text(selected.isEmpty ? "Select photos" : "\(selected.count) selected").font(.subheadline)
                    Spacer()
                    Button(role: .destructive) { Task { await remove() } } label: { Label("Remove from album", systemImage: "minus.circle") }
                        .disabled(selected.isEmpty)
                }
                .padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .fullScreenCover(item: $viewer) { PhotoPager(start: $0).environmentObject(store).environmentObject(router) }
        .notice($notice)
    }

    private func load() async {
        photos = (try? await PhotoList.load([URLQueryItem(name: "ualbum", value: "\(album.id)"), URLQueryItem(name: "sort", value: "old")])) ?? PhotoList()
        loaded = true
    }

    private func remove() async {
        do {
            _ = try await ManageAPI.post("api/ualbums/\(album.id)", ["ids": Array(selected), "on": false])
            notice = Notice(text: "\(ManageAPI.plural(selected.count, "photo")) taken out of the album. They stay in the library.")
            selected = []; selecting = false
            await load()
            await list.load()
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }
}
