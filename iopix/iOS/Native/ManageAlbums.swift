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
    @Published var albums: [Item] = []
    @Published var canShare = false
    @Published var canPrivate = false
    @Published var loaded = false

    func load() async {
        guard let st = try? await ManageAPI.get("api/state") else { loaded = true; return }
        canShare = st["canShareAlbums"] as? Bool ?? false
        canPrivate = st["canPrivateAlbums"] as? Bool ?? false
        albums = (st["albums"] as? [[String: Any]] ?? []).compactMap { a in
            guard let id = (a["id"] as? NSNumber)?.intValue else { return nil }
            return Item(id: id, name: a["name"] as? String ?? "", count: (a["n"] as? NSNumber)?.intValue ?? 0,
                        cover: (a["cover"] as? NSNumber)?.intValue, shared: a["shared"] as? Bool ?? true,
                        mine: a["mine"] as? Bool ?? false, canEdit: a["canEdit"] as? Bool ?? false)
        }
        loaded = true
    }
}

/// Favorites and your albums: make, rename, share or make private, delete; open one to see or remove its photos.
struct ManageAlbumsScreen: View {
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var list = AlbumList()
    @State private var creating = false
    @State private var newName = ""
    @State private var newShared = true
    @State private var renaming: AlbumList.Item?
    @State private var renameText = ""
    @State private var deleting: AlbumList.Item?
    @State private var notice: Notice?

    var body: some View {
        List {
            NavigationLink {
                PhotoGridScreen(query: PhotoQuery([("fav", "1")]), title: "Favorites")
            } label: {
                ThumbRow(cover: nil, title: "Favorites", sub: store.favorites.formatted(), symbol: "heart.fill")
            }
            let shared = list.albums.filter(\.shared), mine = list.albums.filter { !$0.shared }
            if !shared.isEmpty { Section("Shared albums") { ForEach(shared) { row($0) } } }
            if !mine.isEmpty { Section("Only you") { ForEach(mine) { row($0) } } }
            if list.loaded && list.albums.isEmpty {
                Text("No albums yet. Make one here, or select photos and choose Add to album.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Albums")
        .toolbar {
            if list.canShare || list.canPrivate {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newName = ""; newShared = list.canShare; creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New album")
                }
            }
        }
        .task { await list.load() }
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
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { creating = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            let n = newName.trimmingCharacters(in: .whitespaces)
                            creating = false
                            Task { await act("api/ualbums", ["name": n, "shared": list.canShare ? newShared : false], "Album “\(n)” made.") }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .namePrompt("Rename album", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), text: $renameText) { name in
            if let a = renaming { Task { await act("api/ualbums/\(a.id)", ["name": name], "Renamed.") } }
        }
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
