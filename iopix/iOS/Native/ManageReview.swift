import SwiftUI

/// Opens a short list of photos full screen (a duplicate group, a burst).
private struct PagerHost: ViewModifier {
    @Binding var start: PagerStart?
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var router: Router
    func body(content: Content) -> some View {
        content.fullScreenCover(item: $start) { PhotoPager(start: $0).environmentObject(store).environmentObject(router) }
    }
}

extension View {
    func pager(_ start: Binding<PagerStart?>) -> some View { modifier(PagerHost(start: start)) }
}

/// Moves photos to the trash (restorable from the Trash page).
private func trashPhotos(_ ids: [Int]) async -> Notice {
    do {
        let r = try await ManageAPI.post("api/photos/trash", ["ids": ids])
        let n = (r["trashed"] as? [Any])?.count ?? 0, failed = (r["failed"] as? [[String: Any]]) ?? []
        return Notice(text: "\(ManageAPI.plural(n, "photo")) moved to the trash" + (failed.isEmpty ? "." : ", \(failed.count) not: \(failed.first?["error"] as? String ?? "")"),
                      failed: n == 0)
    } catch {
        return Notice(text: error.localizedDescription, failed: true)
    }
}

// MARK: - Duplicate files

/// Files with identical content (same digiKam hash and size), largest first; editors move the extra copies to the
/// trash.
struct ManageDuplicatesScreen: View {
    @AppStorage(ManageThumbSize.key) private var thumbSize = "list"
    struct Copy: Identifiable, Hashable { let id: Int, name: String, album: String, path: String, ratio: Double, video: Bool }
    struct Group: Identifiable, Hashable { let size: Int, items: [Copy]; var id: Int { items.first?.id ?? 0 } }
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var rights = ManageRights()
    @ObservedObject private var catalog = BulkCatalog.shared
    @State private var groups: [Group] = []
    @State private var wasted = 0
    @State private var loaded = false
    @State private var problem: String?
    @State private var viewer: PagerStart?
    @State private var trashing: (Group, Copy)?
    @State private var notice: Notice?

    var body: some View {
        List {
            Section {
                if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else if loaded {
                    Text(groups.isEmpty ? "No duplicate files." : "\(ManageAPI.plural(groups.count, "group")) of identical files · \(ManageAPI.bytes(wasted)) taken by the extra copies.")
                        .foregroundStyle(.secondary)
                } else { ProgressView() }
            }
            ForEach(groups) { g in
                Section("\(g.items.count) copies · \(ManageAPI.bytes(g.size)) each") {
                    ManageThumbStrip(items: g.items.map { .init(id: $0.id, ratio: $0.ratio, caption: "\($0.name)\n\($0.album)") }, height: max(96, ManageThumbSize.side(thumbSize))) { i in
                        viewer = PagerStart(list: PhotoList(ids: g.items.map(\.id)), index: i)
                    }
                    // each copy's folder, as the web app links it under the thumbnail
                    ForEach(g.items) { c in
                        if let album = catalog.folders.first(where: { $0.path == c.path })?.id {
                            NavigationLink {
                                PhotoGridScreen(query: PhotoQuery([("album", "\(album)"), ("sort", "old")]), title: c.album.isEmpty ? "The library root" : (c.album as NSString).lastPathComponent)
                            } label: {
                                Label("\(c.name) in \(c.album.isEmpty ? "the library root" : c.album)", systemImage: "folder").font(.footnote).lineLimit(1)
                            }
                        }
                    }
                    if rights.canWrite {
                        ForEach(g.items) { c in
                            Button(role: .destructive) { trashing = (g, c) } label: {
                                Label("Move \(c.album.isEmpty ? c.name : c.album + "/" + c.name) to the trash", systemImage: "trash").font(.footnote)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Duplicate files")
        .toolbar { ManageThumbSizeMenu() }
        .task { await rights.load(); await catalog.load(); await load() }
        .refreshable { await load() }
        .pager($viewer)
        .confirmationDialog("Move this copy to the trash?", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }), titleVisibility: .visible) {
            Button("Move to trash", role: .destructive) {
                if let (_, c) = trashing { Task { await trash(c) } }
            }
        } message: {
            let name = trashing.map { (_, c) in c.album.isEmpty ? c.name : c.album + "/" + c.name } ?? ""
            Text("\(name)\n\nThe other copies stay. It can be restored from the Trash.")
        }
        .notice($notice)
    }

    /// The copy leaves the list at once (a group with one file left is no longer a duplicate); the server's list
    /// follows once it has rebuilt its index, a moment later, and is read again then.
    private func trash(_ c: Copy) async {
        let seen = await FacesAPI.indexVersion()
        let n = await trashPhotos([c.id])
        notice = n
        guard !n.failed else { return }
        let before = groups
        groups = groups.compactMap { g in
            let left = g.items.filter { $0.id != c.id }
            return left.count > 1 ? Group(size: g.size, items: left) : nil
        }
        if let g = before.first(where: { $0.items.contains { $0.id == c.id } }) { wasted = max(0, wasted - g.size) }
        await FacesAPI.awaitReindex(after: seen)
        await load()
        await store.load()
    }

    private func load() async {
        let j: [String: Any]
        do { j = try await ManageAPI.get("api/duplicates"); problem = nil } catch { problem = error.localizedDescription; loaded = true; return }
        wasted = (j["wasted"] as? NSNumber)?.intValue ?? 0
        groups = (j["groups"] as? [[String: Any]] ?? []).map { g in
            Group(size: (g["size"] as? NSNumber)?.intValue ?? 0, items: (g["items"] as? [[String: Any]] ?? []).compactMap { x in
                guard let id = (x["id"] as? NSNumber)?.intValue else { return nil }
                let w = (x["w"] as? NSNumber)?.doubleValue ?? 0, h = (x["h"] as? NSNumber)?.doubleValue ?? 0
                return Copy(id: id, name: x["name"] as? String ?? "", album: (x["album"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                            path: x["album"] as? String ?? "", ratio: h > 0 ? w / h : 1.4, video: (x["video"] as? NSNumber)?.boolValue ?? false)
            })
        }
        loaded = true
    }
}

// MARK: - Near-duplicates

/// Photos that look almost the same (by the content-search model); an admin can look again at another strictness.
struct ManageNearDuplicatesScreen: View {
    @AppStorage(ManageThumbSize.key) private var thumbSize = "list"
    struct Item: Hashable { let id: Int, name: String, size: Int, ratio: Double, sharp: Double? }
    struct Group: Identifiable, Hashable { let n: Int, score: Double, identical: Bool, items: [Item]; var id: Int { items.first?.id ?? 0 } }
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var rights = ManageRights()
    @State private var groups: [Group] = []
    @State private var enabled = true
    @State private var current = true
    @State private var running = false
    @State private var level = "normal"
    @State private var levels: [String] = ["strict", "normal", "loose"]
    @State private var loaded = false
    @State private var viewer: PagerStart?
    @State private var notice: Notice?

    var body: some View {
        List {
            Section {
                if !enabled {
                    Text("Near-duplicates need content search, which is off on this server.").foregroundStyle(.secondary)
                } else if running {
                    HStack { ProgressView(); Text("Looking for near-duplicates…") }
                } else if loaded {
                    Text(groups.isEmpty ? (current ? "No near-duplicates found." : "Not looked for yet.") : "\(ManageAPI.plural(groups.count, "group")) of photos that look almost the same.")
                        .foregroundStyle(.secondary)
                }
                if rights.isAdmin && enabled {
                    Picker("How alike", selection: $level) {
                        ForEach(levels, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    Button("Look again") { Task { await start() } }.disabled(running)
                }
            }
            ForEach(groups) { g in
                Section("\(g.n) similar · \(Int((g.score * 100).rounded()))% alike" + (g.identical ? " · also byte-identical" : "")) {
                    ManageThumbStrip(items: g.items.map { .init(id: $0.id, ratio: $0.ratio, caption: $0.name + ($0.sharp.map { " · sharpness \(Int(($0 * 100).rounded()))%" } ?? "")) }, height: max(96, ManageThumbSize.side(thumbSize))) { i in
                        viewer = PagerStart(list: PhotoList(ids: g.items.map(\.id)), index: i)
                    }
                }
            }
        }
        .navigationTitle("Near-duplicates")
        .toolbar { ManageThumbSizeMenu() }
        .task { await rights.load(); await load() }
        .refreshable { await load() }
        .pager($viewer)
        .notice($notice)
    }

    private func load() async {
        guard let j = try? await ManageAPI.get("api/neardups") else { loaded = true; return }
        enabled = j["enabled"] as? Bool ?? false
        current = j["current"] as? Bool ?? false
        running = ((j["progress"] as? [String: Any])?["running"] as? Bool) ?? false
        if let l = j["level"] as? String { level = l }
        if let ls = (j["levels"] as? [String: Any])?.keys, !ls.isEmpty { levels = ["strict", "normal", "loose"].filter { ls.contains($0) } }
        groups = (j["groups"] as? [[String: Any]] ?? []).map { g in
            Group(n: (g["n"] as? NSNumber)?.intValue ?? 0, score: (g["score"] as? NSNumber)?.doubleValue ?? 0, identical: g["identical"] as? Bool ?? false,
                  items: (g["items"] as? [[String: Any]] ?? []).compactMap { x in
                      guard let id = (x["id"] as? NSNumber)?.intValue else { return nil }
                      let w = (x["w"] as? NSNumber)?.doubleValue ?? 0, h = (x["h"] as? NSNumber)?.doubleValue ?? 0
                      return Item(id: id, name: x["name"] as? String ?? "", size: (x["size"] as? NSNumber)?.intValue ?? 0,
                                  ratio: h > 0 ? w / h : 1.4, sharp: (x["sharpn"] as? NSNumber)?.doubleValue)
                  })
        }
        loaded = true
        if running {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { await load() }
        }
    }

    private func start() async {
        do {
            _ = try await ManageAPI.post("api/neardups", ["level": level])
            running = true
            await load()
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }
}

// MARK: - Bursts

/// Photos taken in quick succession, newest first, with the best frame picked by sharpness and faces. Editors move
/// the other frames to the trash.
struct ManageBurstsScreen: View {
    @AppStorage(ManageThumbSize.key) private var thumbSize = "list"
    struct Frame: Hashable {
        let id: Int, best: Bool, ratio: Double, ts: Double, sharp: Double?, faces: Double?
        var focus: Double? = nil, looks: Double? = nil, eyesClosed = false, pick = 0
    }
    struct Burst: Identifiable, Hashable { let id: Int, frames: [Frame] }
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var rights = ManageRights()
    @State private var bursts: [Burst] = []
    @State private var total = 0
    @State private var photos = 0
    @State private var loaded = false
    @State private var loading = false
    @State private var problem: String?
    @State private var viewer: PagerStart?
    @State private var keeping: Burst?
    @State private var notice: Notice?

    var body: some View {
        List {
            Section {
                if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else if loaded {
                    Text(total == 0 ? "No bursts found." : "\(ManageAPI.plural(total, "burst")) covering \(ManageAPI.plural(photos, "photo")). Check the best frame before moving the rest to the trash.")
                        .foregroundStyle(.secondary)
                } else { ProgressView() }
            }
            ForEach(bursts) { b in
                Section {
                    ManageThumbStrip(items: b.frames.map { f in
                        .init(id: f.id, ratio: f.ratio,
                              caption: [f.focus.map { "focus \(Int(($0 * 100).rounded()))%" } ?? f.sharp.map { "sharpness \(Int(($0 * 100).rounded()))%" },
                                        f.faces.map { "faces \(Int(($0 * 100).rounded()))%" }, f.looks.map { "looks \(String(format: "%.1f", $0))" },
                                        f.eyesClosed ? "eyes closed" : nil, f.pick == 1 ? "rejected" : nil].compactMap { $0 }.joined(separator: " · "),
                              badge: f.best ? "Best" : nil)
                    }, height: max(96, ManageThumbSize.side(thumbSize))) { i in
                        viewer = PagerStart(list: PhotoList(ids: b.frames.map(\.id), times: b.frames.map(\.ts)), index: i)
                    }
                    NavigationLink("Open in the grid") {
                        PhotoGridScreen(query: PhotoQuery([("burst", "\(b.id)"), ("sort", "old")]), title: "Burst")
                    }
                    if rights.canWrite, b.frames.count > 1 {
                        Button(role: .destructive) { keeping = b } label: { Label("Keep the best, trash the rest", systemImage: "trash") }
                    }
                } header: {
                    Text(PhotoPager.day(b.frames.first?.ts ?? 0) + " · \(b.frames.count) frames")
                }
            }
            if bursts.count < total {
                Button("Show more bursts") { Task { await load(more: true) } }.disabled(loading)
            }
        }
        .navigationTitle("Bursts & best shots")
        .toolbar { ManageThumbSizeMenu() }
        .task { await rights.load(); if !loaded { await load(more: false) } }
        .refreshable { await load(more: false) }
        .pager($viewer)
        .confirmationDialog("Keep the best frame?", isPresented: Binding(get: { keeping != nil }, set: { if !$0 { keeping = nil } }), titleVisibility: .visible) {
            Button("Move the other frames to the trash", role: .destructive) {
                if let b = keeping {
                    let best = b.frames.first { $0.best } ?? b.frames[0]
                    Task {
                        let seen = await FacesAPI.indexVersion()
                        notice = await trashPhotos(b.frames.filter { $0.id != best.id }.map(\.id))
                        await FacesAPI.awaitReindex(after: seen)  // the server's list follows once it has rebuilt
                        await load(more: false); await store.load()
                    }
                }
            }
        } message: { Text("They can be restored from the Trash.") }
        .notice($notice)
    }

    private func load(more: Bool) async {
        loading = true
        defer { loading = false }
        let offset = more ? bursts.count : 0
        let j: [String: Any]
        do {
            j = try await ManageAPI.get("api/bursts", [URLQueryItem(name: "offset", value: "\(offset)"), URLQueryItem(name: "limit", value: "40")])
            problem = nil
        } catch { problem = error.localizedDescription; loaded = true; return }
        total = (j["bursts"] as? NSNumber)?.intValue ?? 0
        photos = (j["photos"] as? NSNumber)?.intValue ?? 0
        let page: [Burst] = (j["groups"] as? [[String: Any]] ?? []).compactMap { g in
            guard let id = (g["burst"] as? NSNumber)?.intValue else { return nil }
            return Burst(id: id, frames: (g["items"] as? [[String: Any]] ?? []).compactMap { x in
                guard let pid = (x["id"] as? NSNumber)?.intValue else { return nil }
                let w = (x["w"] as? NSNumber)?.doubleValue ?? 0, h = (x["h"] as? NSNumber)?.doubleValue ?? 0
                return Frame(id: pid, best: (x["best"] as? NSNumber)?.boolValue ?? false, ratio: h > 0 ? w / h : 1.4,
                             ts: (x["ts"] as? NSNumber)?.doubleValue ?? 0, sharp: (x["sharpn"] as? NSNumber)?.doubleValue,
                             faces: (x["faceq"] as? NSNumber)?.doubleValue, focus: (x["focusn"] as? NSNumber)?.doubleValue,
                             looks: (x["aesthetic"] as? NSNumber)?.doubleValue, eyesClosed: ((x["eyesClosed"] as? NSNumber)?.intValue ?? 0) > 0,
                             pick: (x["pick"] as? NSNumber)?.intValue ?? 0)
            })
        }
        bursts = more ? bursts + page : page
        loaded = true
    }
}

// MARK: - Detected content

/// What the content-search model recognises in the photos (beach, dogs, birthday cake...), by group.
struct ManageDetectedScreen: View {
    struct Concept: Identifiable, Hashable { let group: String, name: String, n: Int, cover: Int?; var id: String { group + name } }
    @State private var concepts: [Concept] = []
    @State private var enabled = true
    @State private var indexing = false
    @State private var loaded = false
    @State private var search = ""

    var body: some View {
        let shown = concepts.filter { $0.n > 0 && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
        let groups = Dictionary(grouping: shown, by: \.group)
        List {
            if !enabled {
                Text("Content search is off on this server.").foregroundStyle(.secondary)
            } else if indexing {
                Label("Still learning the photos' content; more appears as it goes.", systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
            }
            if loaded && enabled && shown.isEmpty { Text(search.isEmpty ? "Nothing detected yet." : "Nothing called “\(search)”.").foregroundStyle(.secondary) }
            ForEach(groups.keys.sorted(), id: \.self) { g in
                Section(g.isEmpty ? "Other" : g) {
                    ForEach((groups[g] ?? []).sorted { $0.n > $1.n }) { c in
                        NavigationLink {
                            PhotoGridScreen(query: PhotoQuery([("concept", c.name)]), title: c.name.prefix(1).uppercased() + c.name.dropFirst())
                        } label: {
                            ThumbRow(cover: c.cover, title: c.name.prefix(1).uppercased() + c.name.dropFirst(), sub: c.n.formatted(), symbol: "sparkles")
                        }
                    }
                }
            }
        }
        .navigationTitle("Detected content")
        .searchable(text: $search, prompt: "Find something")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let j = try? await ManageAPI.get("api/concepts") else { loaded = true; return }
        enabled = j["enabled"] as? Bool ?? false
        indexing = j["indexing"] as? Bool ?? false
        concepts = (j["concepts"] as? [[String: Any]] ?? []).compactMap { c in
            guard let name = c["name"] as? String else { return nil }
            return Concept(group: c["group"] as? String ?? "", name: name, n: (c["n"] as? NSNumber)?.intValue ?? 0, cover: (c["cover"] as? NSNumber)?.intValue)
        }
        loaded = true
    }
}

// MARK: - Metadata quality

/// Maintenance › Metadata quality: face boxes stored twice, the same person twice, boxes outside the photo, unnamed
/// faces, untagged photos, photos without a location, in the wrong folder or with a doubtful date. Each list opens
/// its photos; editors can trim boxes, ignore unnamed faces, accept findings, or clean up the doubled boxes.
struct ManageQualityScreen: View {
    @AppStorage(ManageThumbSize.key) private var thumbSize = "list"
    /// One finding of the location, date and folder checks, with what its inline fixes need: the folder it is in,
    /// the date its folder is named for (baddate) and the folder its date belongs in (wrongfolder).
    struct Item: Identifiable, Hashable {
        let photo: Int, name: String, ts: Double, taken: String, reason: String, folder: String, folderID: Int?
        let folderDate: String?, suggestID: Int?, suggestPath: String?, expect: String
        /// The face checks' line under the name ("3 unnamed faces", "2 people detected").
        var line = ""
        var id: Int { photo }
    }
    struct Check: Identifiable {
        let key: String, title: String, detail: String, count: Int, photos: [Int], accepted: Int
        var items: [Item] = []
        var id: String { key }
    }
    /// Photos for a sheet (the location or date editor).
    private struct Picked: Identifiable { let ids: [Int]; var id: String { ids.map(String.init).joined(separator: ",") } }
    /// The checks whose rows list each photo with its inline fixes (the others show a strip of thumbnails).
    private static let rowChecks: Set<String> = ["nolocation", "baddate", "wrongfolder"]
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var rights = ManageRights()
    @ObservedObject private var catalog = BulkCatalog.shared
    @StateObject private var tree = FolderTree()
    @State private var checks: [Check] = []
    @State private var checkedAt: Double?
    @State private var running = false
    @State private var loaded = false
    @State private var problem: String?
    @State private var viewer: PagerStart?
    @State private var confirm: String?
    @State private var ignoring: [Int] = []
    @State private var notice: Notice?
    // ticked rows belong to one check at a time (a trip's photos to place together); the bar at the bottom acts on them
    @State private var ticked: Set<Int> = []
    @State private var tickedCheck = ""
    @State private var locating: Picked?
    @State private var dating: Picked?
    @State private var movePick: Item?
    @State private var folderDating: [Item]?
    @State private var openFolder: Item?
    /// How many rows each check shows; "Load the next 40" adds to it, as the web app's lists do.
    @State private var shown: [String: Int] = [:]
    private static let page = 40

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(.secondary) }
            if let at = checkedAt, at > 0 {
                Text("Checked \(Date(timeIntervalSince1970: at).formatted(.relative(presentation: .named))).").font(.footnote).foregroundStyle(.secondary)
            }
            if running { HStack { ProgressView(); Text("Cleaning up in the background…") } }
            ForEach(checks) { c in
                Section {
                    HStack {
                        Text(c.detail).font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Text(c.count.formatted()).font(.headline).foregroundStyle(c.count == 0 ? Hue.green : Hue.amber)
                    }
                    if rights.canWrite && c.count > 0 { actions(c) }
                    // every check is a list of its photos with their fixes, as on the web, loaded a page at a time
                    let limit = shown[c.key] ?? Self.page
                    ForEach(c.items.prefix(limit)) { x in itemRow(c, x) }
                    if c.items.count > limit {
                        Button {
                            shown[c.key] = limit + Self.page
                        } label: {
                            Text("Load the next \(min(Self.page, c.items.count - limit))") + Text(" · \((c.items.count - limit).formatted()) more").foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                    } else if c.count > c.items.count {
                        Text("The first \(c.items.count.formatted()) of \(c.count.formatted()); check again after fixing these for the rest.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if c.accepted > 0 {
                        Button("Show the \(ManageAPI.plural(c.accepted, "accepted photo")) again") { Task { await unaccept(c.key) } }.font(.footnote)
                    }
                } header: { Text(c.title) }
            }
        }
        .navigationTitle("Metadata quality")
        .toolbar { ManageThumbSizeMenu() }
        .safeAreaInset(edge: .bottom) { if !ticked.isEmpty { tickedBar } }
        .task { await rights.load(); await catalog.load(); await load() }
        .refreshable { await load() }
        .pager($viewer)
        .navigationDestination(item: $openFolder) { x in
            PhotoGridScreen(query: PhotoQuery([("album", "\(x.folderID ?? 0)"), ("sort", "old")]), title: x.folder.isEmpty ? "The library root" : (x.folder as NSString).lastPathComponent)
        }
        .sheet(item: $locating) { p in BulkLocationSheet(ids: p.ids) { Task { untickAll(); await load() } } }
        .sheet(item: $dating) { p in BulkEditSheet(ids: p.ids) { Task { untickAll(); await load() } } }
        .sheet(item: $movePick) { x in
            FolderPicker(tree: tree, excluding: [], root: tree.node(x.folderID)?.root ?? 0, title: "Move \(x.name) into") { target in
                Task { await move([x.photo], to: target) }
            }
        }
        .confirmationDialog("Date \(ManageAPI.plural(folderDating?.count ?? 0, "photo")) from the folder \((folderDating?.count ?? 0) == 1 ? "it is" : "they are") in (its date, at noon)?",
                            isPresented: Binding(get: { folderDating != nil }, set: { if !$0 { folderDating = nil } }), titleVisibility: .visible) {
            Button("Take the folder’s date") { if let list = folderDating { Task { await useFolderDate(list) } } }
        }
        .confirmationDialog(confirm == "files" ? "Clean up the image files too?" : "Remove the doubled face boxes?", isPresented: Binding(get: { confirm != nil && confirm != "ignore" }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirm == "files" ? "Clean up image files" : "Remove doubles", role: .destructive) {
                let files = confirm == "files"
                Task { await act("api/quality/fix", ["files": files]) { r in "Cleaning up \(ManageAPI.plural((r["photos"] as? NSNumber)?.intValue ?? 0, files ? "image file" : "photo")) in the background." } }
            }
        } message: { Text("One box is kept in each group of near-identical boxes; the sidecars are rewritten. A backup is taken first.") }
        .confirmationDialog("Ignore the unnamed faces on \(ManageAPI.plural(ignoring.count, "photo"))?", isPresented: Binding(get: { confirm == "ignore" }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button("Ignore these faces", role: .destructive) {
                let photos = ignoring
                Task { await act("api/quality/ignore", ["photos": photos]) { r in "\(ManageAPI.plural((r["ignored"] as? NSNumber)?.intValue ?? 0, "face")) ignored." } }
            }
        } message: { Text("They become faces not to name. Each change is in the history, with undo.") }
        .notice($notice)
    }

    @ViewBuilder private func actions(_ c: Check) -> some View {
        switch c.key {
        case "near":
            Button("Remove the doubled boxes") { confirm = "db" }
            Button("Also clean up the image files…") { confirm = "files" }
        case "invalid":
            Button("Trim every box to its photo") {
                Task { await act("api/quality/fit", [:]) { r in "\((r["fitted"] as? NSNumber)?.intValue ?? 0) trimmed, \((r["removed"] as? NSNumber)?.intValue ?? 0) removed." } }
            }
        case "unnamed":
            Button("Ignore these unnamed faces") { ignoring = c.photos; confirm = "ignore" }
            Button("Accept them as they are") { Task { await accept(c.key, c.photos) } }
        case "untagged":
            if catalog.canManage { Button("Find faces in all shown") { Task { await findFaces(c.photos) } } }
            Button("Accept all shown") { Task { await accept(c.key, c.photos) } }
        case "nolocation":
            if catalog.editing {
                Button(tickedCheck == c.key && ticked.count >= c.items.count ? "Untick all" : "Tick all shown") { tickAll(c, on: !(tickedCheck == c.key && ticked.count >= c.items.count)) }
                Button("Set location for all shown") { locating = Picked(ids: c.items.map(\.photo)) }
            }
            Button("Accept all shown") { Task { await accept(c.key, c.photos) } }
        case "baddate":
            let withFolder = c.items.filter { $0.folderDate != nil }
            if catalog.editing && !withFolder.isEmpty {
                Button("Take the folder’s date for \(withFolder.count.formatted())") { folderDating = withFolder }
            }
            Button("Accept all shown") { Task { await accept(c.key, c.photos) } }
        case "wrongfolder":
            Button("Accept all shown") { Task { await accept(c.key, c.photos) } }
        default:
            EmptyView()
        }
    }

    /// One finding, with the inline fixes the web app offers for it: set the location, set or fix the date, take the
    /// folder's date, move the file to the folder for its date, or accept it as it is.
    private func itemRow(_ c: Check, _ x: Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if catalog.editing {
                let on = tickedCheck == c.key && ticked.contains(x.photo)
                Button { tick(c, x.photo) } label: { Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title3) }
                    .buttonStyle(.borderless).accessibilityLabel("Tick \(x.name)")
            }
            Button { viewer = PagerStart(list: PhotoList(ids: c.photos), index: c.photos.firstIndex(of: x.photo) ?? 0) } label: {
                RemoteImage(path: "thumb/\(x.photo)").frame(width: ManageThumbSize.side(thumbSize) * 4 / 3, height: ManageThumbSize.side(thumbSize)).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(x.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(itemDetail(c.key, x)).font(.caption).foregroundStyle(.secondary)
                if x.folderID != nil, c.key != "nolocation" {
                    Button("in \(x.folder.isEmpty ? "the library root" : x.folder)") { openFolder = x }.buttonStyle(.borderless).font(.caption)
                }
                FlowLayout(spacing: 12) {
                    switch c.key {
                    case "nolocation":
                        if catalog.editing { Button("Set location") { locating = Picked(ids: [x.photo]) } }
                    case "baddate":
                        if catalog.editing {
                            Button("Set the date") { dating = Picked(ids: [x.photo]) }
                            if let fd = x.folderDate { Button("Use the folder’s date (\(fd.prefix(10)))") { Task { await useFolderDate([x]) } } }
                        }
                    case "wrongfolder":
                        if catalog.editing { Button("Fix the date") { dating = Picked(ids: [x.photo]) } }
                        if catalog.canManage {
                            if let path = x.suggestPath { Button("Move to \(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))") { Task { await moveToDateFolder([x]) } } }
                            else { Button("Move to a folder…") { Task { if !tree.loaded { await tree.load() }; movePick = x } } }
                        }
                    case "unnamed":
                        Button("Name them") { nameThem(c, x) }
                        if catalog.canManage { Button("Ignore") { ignoring = [x.photo]; confirm = "ignore" } }
                    case "untagged":
                        if catalog.canManage { Button("Find faces") { Task { await findFaces([x.photo]) } } }
                    default: EmptyView()
                    }
                    if ["nolocation", "baddate", "wrongfolder", "unnamed", "untagged"].contains(c.key) {
                        Button("Accept as it is") { Task { await accept(c.key, [x.photo]) } }
                    }
                }
                .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    /// The photo in the viewer with its face boxes shown, to name them there (the web app's "Name them").
    private func nameThem(_ c: Check, _ x: Item) {
        UserDefaults.standard.set(true, forKey: "iopix.viewer.faces")
        viewer = PagerStart(list: PhotoList(ids: c.photos), index: c.photos.firstIndex(of: x.photo) ?? 0)
    }

    private func findFaces(_ ids: [Int]) async {
        await act("api/faces/detect", ["ids": ids]) { r in
            if r["done"] as? Bool == true { return "\(ManageAPI.plural((r["added"] as? NSNumber)?.intValue ?? 0, "face")) found; name them from the photo, or under Unnamed faces after checking again." }
            return "Looking for faces in \(ManageAPI.plural((r["queued"] as? NSNumber)?.intValue ?? ids.count, "photo")) in the background."
        }
    }

    private func itemDetail(_ key: String, _ x: Item) -> String {
        if !x.line.isEmpty { return x.line }
        let day = x.ts > 0 ? Date(timeIntervalSince1970: x.ts).formatted(date: .abbreviated, time: .omitted) : nil
        switch key {
        case "nolocation": return day ?? "no date"
        case "baddate": return "\(x.taken.replacingOccurrences(of: "T", with: " ")) · \(x.reason)"
        default: return "taken \(day ?? String(x.taken.prefix(10)))" + (x.expect.isEmpty ? "" : " · a folder for \(x.expect)")
        }
    }

    // MARK: ticking several rows

    private func tick(_ c: Check, _ photo: Int) {
        if tickedCheck != c.key { ticked = []; tickedCheck = c.key }
        if ticked.contains(photo) { ticked.remove(photo) } else { ticked.insert(photo) }
    }

    private func tickAll(_ c: Check, on: Bool) {
        tickedCheck = c.key
        ticked = on ? Set(c.items.map(\.photo)) : []
    }

    private func untickAll() { ticked = [] }

    private var tickedItems: [Item] { checks.first { $0.key == tickedCheck }?.items.filter { ticked.contains($0.photo) } ?? [] }

    /// Fixed at the bottom while rows are ticked: the fixes for all of them together, as the web app's bar.
    private var tickedBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(ManageAPI.plural(ticked.count, "photo")) ticked").font(.subheadline.weight(.medium))
                Spacer()
                Button("Untick all") { untickAll() }.font(.subheadline)
            }
            FlowLayout(spacing: 8) {
                let items = tickedItems
                switch tickedCheck {
                case "nolocation":
                    Button("Set their location…") { locating = Picked(ids: Array(ticked)) }.buttonStyle(.borderedProminent)
                case "baddate":
                    Button("Set their date…") { dating = Picked(ids: Array(ticked)) }.buttonStyle(.borderedProminent)
                    let withFolder = items.filter { $0.folderDate != nil }
                    if !withFolder.isEmpty { Button("Use the folder’s date for \(withFolder.count)") { folderDating = withFolder }.buttonStyle(.bordered) }
                case "wrongfolder":
                    Button("Fix their date…") { dating = Picked(ids: Array(ticked)) }.buttonStyle(.borderedProminent)
                    let movable = items.filter { $0.suggestID != nil }
                    if catalog.canManage && !movable.isEmpty { Button("Move \(movable.count) to the folder for their date") { Task { await moveToDateFolder(movable) } }.buttonStyle(.bordered) }
                default: EmptyView()
                }
                Button("Accept them as they are") { let ids = Array(ticked), key = tickedCheck; Task { await accept(key, ids); untickAll() } }.buttonStyle(.bordered)
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    // MARK: the fixes

    /// The date the folder is named for (at noon), as the photo's date.
    private func useFolderDate(_ list: [Item]) async {
        var n = 0
        for x in list { if let fd = x.folderDate, await BulkEdit.apply([x.photo], ["taken": fd], quiet: true) { n += 1 } }
        notice = Notice(text: "\(ManageAPI.plural(n, "photo")) dated from \(n == 1 ? "its" : "their") folder.", failed: n == 0)
        untickAll()
        await load()
    }

    /// Moves each file (with its sidecar) to the folder for its date, as the check suggests.
    private func moveToDateFolder(_ list: [Item]) async {
        var by: [Int: [Int]] = [:]
        for x in list { if let a = x.suggestID { by[a, default: []].append(x.photo) } }
        var n = 0, failed = 0
        for (album, ids) in by {
            do {
                let r = try await ManageAPI.post("api/photos/move", ["ids": ids, "album": album])
                n += (r["moved"] as? [Any])?.count ?? 0
                failed += (r["failed"] as? [Any])?.count ?? 0
            } catch { notice = Notice(text: error.localizedDescription, failed: true); return }
        }
        notice = Notice(text: "\(ManageAPI.plural(n, "photo")) moved to the folder for \(n == 1 ? "its" : "their") date" + (failed > 0 ? "; \(failed) could not be." : "."), failed: n == 0)
        untickAll()
        await load()
        await store.load()
    }

    private func move(_ ids: [Int], to album: Int) async {
        do {
            let r = try await ManageAPI.post("api/photos/move", ["ids": ids, "album": album])
            let n = (r["moved"] as? [Any])?.count ?? 0, failed = (r["failed"] as? [[String: Any]]) ?? []
            notice = Notice(text: "\(ManageAPI.plural(n, "photo")) moved" + (failed.isEmpty ? "." : "; \(failed.count) not: \(failed.first?["error"] as? String ?? "")"), failed: n == 0)
            await load()
            await store.load()
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }

    private static let titles: [(String, String, String)] = [
        ("near", "Face boxes stored twice", "The same face marked twice, a little apart."),
        ("separate", "One person, two names", "The same person in two places of the tag tree."),
        ("invalid", "Boxes outside the photo", "Face boxes that stick out of their photo or are empty."),
        ("unnamed", "Faces without a name", "Photos with faces where none is named. Name them, mark them as not faces to name, or accept the photo as it is."),
        ("untagged", "People, but nobody tagged", "Object detection sees people, but no face is marked and no person is tagged (crowds, people from behind, strangers)."),
        ("nolocation", "No location", "Photos and videos with no place."),
        ("wrongfolder", "In the wrong folder", "Photos whose date doesn't match their dated folder."),
        ("baddate", "Doubtful date", "Photos whose date looks wrong."),
    ]

    private func load() async {
        do {
            let j = try await ManageAPI.get("api/quality")
            checkedAt = (j["at"] as? NSNumber)?.doubleValue
            running = ((j["progress"] as? [String: Any])?["running"] as? Bool) ?? false
            checks = Self.titles.compactMap { key, title, detail in
                guard let s = j[key] as? [String: Any] else { return nil }
                let count = (s["count"] as? NSNumber)?.intValue ?? (s["groups"] as? NSNumber)?.intValue ?? 0
                let list = (s["items"] as? [[String: Any]]) ?? (s["examples"] as? [[String: Any]]) ?? []
                var seen = Set<Int>()
                let photos = list.compactMap { ($0["photo"] as? NSNumber)?.intValue }.filter { seen.insert($0).inserted }
                var c = Check(key: key, title: title, detail: detail, count: count, photos: photos, accepted: (s["accepted"] as? NSNumber)?.intValue ?? 0)
                var seenRows = Set<Int>()
                c.items = list.compactMap { x -> Item? in
                    guard let id = (x["photo"] as? NSNumber)?.intValue, seenRows.insert(id).inserted else { return nil }
                    let sug = x["suggest"] as? [String: Any]
                    let n = { (k: String) in (x[k] as? NSNumber)?.intValue ?? 0 }
                    // the face checks' line, in the web app's words
                    let line: String
                    switch key {
                    case "unnamed": line = ManageAPI.plural(n("faces"), "unnamed face")
                    case "untagged": line = "\(n("people") == 1 ? "1 person" : "\(n("people")) people") detected"
                    case "separate": line = "\((x["rects"] as? [Any])?.count ?? 0) boxes of the same person"
                    case "near": line = (x["apart"] as? NSNumber).map { "two boxes \($0.intValue) px apart" } ?? "the same face marked twice"
                    case "invalid": line = x["reason"] as? String ?? "a box outside the photo"
                    default: line = ""
                    }
                    return Item(photo: id, name: x["name"] as? String ?? "", ts: (x["ts"] as? NSNumber)?.doubleValue ?? 0,
                                taken: x["taken"] as? String ?? "", reason: x["reason"] as? String ?? "",
                                folder: (x["folder"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                                folderID: (x["folder_id"] as? NSNumber)?.intValue, folderDate: x["folder_date"] as? String,
                                suggestID: (sug?["id"] as? NSNumber)?.intValue, suggestPath: sug?["path"] as? String, expect: x["expect"] as? String ?? "", line: line)
                }
                return c
            }
            // ticks of rows that left the list go with them
            if let c = checks.first(where: { $0.key == tickedCheck }) { ticked = ticked.intersection(c.items.map(\.photo)) } else { ticked = [] }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    private func act(_ path: String, _ body: [String: Any], _ text: @escaping ([String: Any]) -> String) async {
        do {
            let r = try await ManageAPI.post(path, body)
            notice = Notice(text: text(r))
            await load()
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }

    private func accept(_ check: String, _ photos: [Int]) async {
        await act("api/quality/accept", ["photos": photos, "check": check, "on": true]) { _ in "\(ManageAPI.plural(photos.count, "photo")) accepted as they are." }
    }

    private func unaccept(_ check: String) async {
        guard let j = try? await ManageAPI.get("api/quality/accepted", [URLQueryItem(name: "check", value: check)]) else { return }
        let photos = (j["photos"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        guard !photos.isEmpty else { return }
        await act("api/quality/accept", ["photos": photos, "check": check, "on": false]) { _ in "They show in the list again." }
    }
}

// MARK: - History

/// Every change made in iopix, newest first: who, when and what; searchable. Editors can undo a change or put back
/// the backup a change kept.
struct ManageHistoryScreen: View {
    @AppStorage(ManageThumbSize.key) private var thumbSize = "list"
    struct Entry: Identifiable, Hashable {
        let id: Int, photo: Int?, ts: Double, user: String, action: String, summary: String, path: String, restore: [String]
    }
    var photo: Int? = nil
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var rights = ManageRights()
    @State private var entries: [Entry] = []
    @State private var total = 0
    @State private var search = ""
    @State private var sent = ""
    @State private var action = ""
    // the web app's filters: a person (their tag), who made the change, and a range of days
    @State private var person: Int?
    @State private var user = ""
    @State private var users: [String] = []
    @State private var fromOn = false
    @State private var from = Date()
    @State private var untilOn = false
    @State private var until = Date()
    @State private var loaded = false
    @State private var problem: String?
    @State private var viewer: PagerStart?
    @State private var notice: Notice?

    private static let actions: [(String, String)] = [("", "All changes"), ("edit", "Edits"), ("lossless", "Files"), ("tag", "Tags"), ("face", "Faces"), ("moved", "Moved"),
                                                      ("trashed", "Trashed"), ("deleted", "Deleted"), ("added", "Added"), ("restore", "Restores"), ("revert", "Undone"),
                                                      ("guard", "Protected"), ("sync", "Sync"), ("database", "digiKam")]
    private static let restoreLabels = ["undo": "Undo", "trash": "Restore from trash", "sidecar": "Put the sidecar back",
                                        "deleted": "Bring the photo back", "original": "Put the original file back"]

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $action) { ForEach(Self.actions, id: \.0) { Text($0.1).tag($0.0) } }
                let people = store.people.filter { $0.all > 0 || $0.count > 0 }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                if !people.isEmpty {
                    Picker("Person", selection: $person) {
                        Text("Any person").tag(Int?.none)
                        ForEach(people) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                }
                if !users.isEmpty {
                    Picker("By", selection: $user) {
                        Text("Anyone").tag("")
                        ForEach(users, id: \.self) { Text($0).tag($0) }
                    }
                }
                Toggle("From a day", isOn: $fromOn)
                if fromOn { DatePicker("From", selection: $from, displayedComponents: .date) }
                Toggle("Until a day", isOn: $untilOn)
                if untilOn { DatePicker("Until", selection: $until, displayedComponents: .date) }
                if loaded { Text(ManageAPI.plural(total, "change")).font(.footnote).foregroundStyle(.secondary) }
            }
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        if let p = e.photo {
                            Button { viewer = PagerStart(list: PhotoList(ids: [p]), index: 0) } label: {
                                RemoteImage(path: "thumb/\(p)").frame(width: ManageThumbSize.side(thumbSize) * 4 / 3, height: ManageThumbSize.side(thumbSize)).clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.summary).font(.subheadline)
                            Text((e.path as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text("\(e.action.capitalized) · \(e.user) · \(Date(timeIntervalSince1970: e.ts).formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if rights.canWrite && !e.restore.isEmpty {
                        HStack(spacing: 14) {
                            ForEach(e.restore, id: \.self) { k in
                                Button(Self.restoreLabels[k] ?? k.capitalized) { Task { await restore(e, k) } }.font(.caption).buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            if entries.count < total {
                Button("Show more") { Task { await load(more: true) } }
            }
            if let problem { Text(problem).foregroundStyle(.secondary) }
            if loaded && entries.isEmpty && problem == nil { Text("No changes yet.").foregroundStyle(.secondary) }
        }
        .navigationTitle(photo == nil ? "History" : "This photo's history")
        .toolbar { ManageThumbSizeMenu() }
        .searchable(text: $search, prompt: "Search changes, file names, people")
        .onSubmit(of: .search) { sent = search }
        .onChange(of: search) { _, s in if s.isEmpty { sent = "" } }
        .task(id: "\(sent)|\(action)|\(person ?? 0)|\(user)|\(since ?? 0)|\(untilStamp ?? 0)") { await rights.load(); await load(more: false) }
        .refreshable { await load(more: false) }
        .pager($viewer)
        .notice($notice)
    }

    /// The range as the web app sends it: from the start of the first day to the end of the last (local time).
    private var since: Int? { fromOn ? Int(Calendar.current.startOfDay(for: from).timeIntervalSince1970) : nil }
    private var untilStamp: Int? { untilOn ? Int(Calendar.current.startOfDay(for: until).timeIntervalSince1970) + 86400 : nil }

    private func load(more: Bool) async {
        var q = [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "offset", value: "\(more ? entries.count : 0)")]
        if !sent.isEmpty { q.append(URLQueryItem(name: "q", value: sent)) }
        if !action.isEmpty { q.append(URLQueryItem(name: "action", value: action)) }
        if let photo { q.append(URLQueryItem(name: "photo", value: "\(photo)")) }
        if let person { q.append(URLQueryItem(name: "person", value: "\(person)")) }
        if !user.isEmpty { q.append(URLQueryItem(name: "user", value: user)) }
        if let since { q.append(URLQueryItem(name: "since", value: "\(since)")) }
        if let untilStamp { q.append(URLQueryItem(name: "until", value: "\(untilStamp)")) }
        let j: [String: Any]
        do { j = try await ManageAPI.get("api/history", q); problem = nil } catch { problem = error.localizedDescription; loaded = true; return }
        total = (j["total"] as? NSNumber)?.intValue ?? 0
        if let u = j["users"] as? [String], !u.isEmpty { users = u }  // who has made changes (the server lists them once)
        let page: [Entry] = (j["entries"] as? [[String: Any]] ?? []).compactMap { e in
            guard let id = (e["id"] as? NSNumber)?.intValue else { return nil }
            return Entry(id: id, photo: (e["photo"] as? NSNumber)?.intValue, ts: (e["ts"] as? NSNumber)?.doubleValue ?? 0, user: e["user"] as? String ?? "",
                         action: e["action"] as? String ?? "", summary: e["summary"] as? String ?? "", path: e["path"] as? String ?? "",
                         restore: e["restore"] as? [String] ?? [])
        }
        entries = more ? entries + page : page
        loaded = true
    }

    private func restore(_ e: Entry, _ kind: String) async {
        do {
            _ = try await ManageAPI.post("api/history/\(e.id)/restore", ["kind": kind])
            notice = Notice(text: kind == "deleted" ? "Photo restored." : "Restored.")
            await load(more: false)
            await store.load()
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }
}
