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

private extension View {
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
    struct Copy: Identifiable, Hashable { let id: Int, name: String, album: String, ratio: Double, video: Bool }
    struct Group: Identifiable, Hashable { let size: Int, items: [Copy]; var id: Int { items.first?.id ?? 0 } }
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var rights = ManageRights()
    @State private var groups: [Group] = []
    @State private var wasted = 0
    @State private var loaded = false
    @State private var viewer: PagerStart?
    @State private var trashing: (Group, Copy)?
    @State private var notice: Notice?

    var body: some View {
        List {
            Section {
                if loaded {
                    Text(groups.isEmpty ? "No duplicate files." : "\(ManageAPI.plural(groups.count, "group")) of identical files · \(ManageAPI.bytes(wasted)) taken by the extra copies.")
                        .foregroundStyle(.secondary)
                } else { ProgressView() }
            }
            ForEach(groups) { g in
                Section("\(g.items.count) copies · \(ManageAPI.bytes(g.size)) each") {
                    ManageThumbStrip(items: g.items.map { .init(id: $0.id, ratio: $0.ratio, caption: "\($0.name)\n\($0.album)") }, height: 96) { i in
                        viewer = PagerStart(list: PhotoList(ids: g.items.map(\.id)), index: i)
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
        .task { await rights.load(); await load() }
        .refreshable { await load() }
        .pager($viewer)
        .confirmationDialog("Move this copy to the trash?", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }), titleVisibility: .visible) {
            Button("Move to trash", role: .destructive) {
                if let (_, c) = trashing { Task { notice = await trashPhotos([c.id]); await load(); await store.load() } }
            }
        } message: { Text("The other copies stay. It can be restored from the Trash.") }
        .notice($notice)
    }

    private func load() async {
        guard let j = try? await ManageAPI.get("api/duplicates") else { loaded = true; return }
        wasted = (j["wasted"] as? NSNumber)?.intValue ?? 0
        groups = (j["groups"] as? [[String: Any]] ?? []).map { g in
            Group(size: (g["size"] as? NSNumber)?.intValue ?? 0, items: (g["items"] as? [[String: Any]] ?? []).compactMap { x in
                guard let id = (x["id"] as? NSNumber)?.intValue else { return nil }
                let w = (x["w"] as? NSNumber)?.doubleValue ?? 0, h = (x["h"] as? NSNumber)?.doubleValue ?? 0
                return Copy(id: id, name: x["name"] as? String ?? "", album: (x["album"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                            ratio: h > 0 ? w / h : 1.4, video: (x["video"] as? NSNumber)?.boolValue ?? false)
            })
        }
        loaded = true
    }
}

// MARK: - Near-duplicates

/// Photos that look almost the same (by the content-search model); an admin can look again at another strictness.
struct ManageNearDuplicatesScreen: View {
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
                    ManageThumbStrip(items: g.items.map { .init(id: $0.id, ratio: $0.ratio, caption: $0.name + ($0.sharp.map { " · sharpness \(Int(($0 * 100).rounded()))%" } ?? "")) }, height: 96) { i in
                        viewer = PagerStart(list: PhotoList(ids: g.items.map(\.id)), index: i)
                    }
                }
            }
        }
        .navigationTitle("Near-duplicates")
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
            await load()
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
    struct Frame: Hashable { let id: Int, best: Bool, ratio: Double, ts: Double, sharp: Double?, faces: Double? }
    struct Burst: Identifiable, Hashable { let id: Int, frames: [Frame] }
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var rights = ManageRights()
    @State private var bursts: [Burst] = []
    @State private var total = 0
    @State private var photos = 0
    @State private var loaded = false
    @State private var loading = false
    @State private var viewer: PagerStart?
    @State private var keeping: Burst?
    @State private var notice: Notice?

    var body: some View {
        List {
            Section {
                if loaded {
                    Text(total == 0 ? "No bursts found." : "\(ManageAPI.plural(total, "burst")) covering \(ManageAPI.plural(photos, "photo")). Check the best frame before moving the rest to the trash.")
                        .foregroundStyle(.secondary)
                } else { ProgressView() }
            }
            ForEach(bursts) { b in
                Section {
                    ManageThumbStrip(items: b.frames.map { f in
                        .init(id: f.id, ratio: f.ratio,
                              caption: [f.sharp.map { "sharpness \(Int(($0 * 100).rounded()))%" }, f.faces.map { "faces \(Int(($0 * 100).rounded()))%" }].compactMap { $0 }.joined(separator: " · "),
                              badge: f.best ? "Best" : nil)
                    }, height: 96) { i in
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
        .task { await rights.load(); if !loaded { await load(more: false) } }
        .refreshable { await load(more: false) }
        .pager($viewer)
        .confirmationDialog("Keep the best frame?", isPresented: Binding(get: { keeping != nil }, set: { if !$0 { keeping = nil } }), titleVisibility: .visible) {
            Button("Move the other frames to the trash", role: .destructive) {
                if let b = keeping {
                    let best = b.frames.first { $0.best } ?? b.frames[0]
                    Task { notice = await trashPhotos(b.frames.filter { $0.id != best.id }.map(\.id)); await load(more: false); await store.load() }
                }
            }
        } message: { Text("They can be restored from the Trash.") }
        .notice($notice)
    }

    private func load(more: Bool) async {
        loading = true
        defer { loading = false }
        let offset = more ? bursts.count : 0
        guard let j = try? await ManageAPI.get("api/bursts", [URLQueryItem(name: "offset", value: "\(offset)"), URLQueryItem(name: "limit", value: "40")]) else { loaded = true; return }
        total = (j["bursts"] as? NSNumber)?.intValue ?? 0
        photos = (j["photos"] as? NSNumber)?.intValue ?? 0
        let page: [Burst] = (j["groups"] as? [[String: Any]] ?? []).compactMap { g in
            guard let id = (g["burst"] as? NSNumber)?.intValue else { return nil }
            return Burst(id: id, frames: (g["items"] as? [[String: Any]] ?? []).compactMap { x in
                guard let pid = (x["id"] as? NSNumber)?.intValue else { return nil }
                let w = (x["w"] as? NSNumber)?.doubleValue ?? 0, h = (x["h"] as? NSNumber)?.doubleValue ?? 0
                return Frame(id: pid, best: (x["best"] as? NSNumber)?.boolValue ?? false, ratio: h > 0 ? w / h : 1.4,
                             ts: (x["ts"] as? NSNumber)?.doubleValue ?? 0, sharp: (x["sharpn"] as? NSNumber)?.doubleValue,
                             faces: (x["faceq"] as? NSNumber)?.doubleValue)
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
    struct Check: Identifiable {
        let key: String, title: String, detail: String, count: Int, photos: [Int], accepted: Int
        var id: String { key }
    }
    @StateObject private var rights = ManageRights()
    @State private var checks: [Check] = []
    @State private var checkedAt: Double?
    @State private var running = false
    @State private var loaded = false
    @State private var problem: String?
    @State private var viewer: PagerStart?
    @State private var confirm: String?
    @State private var notice: Notice?

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
                    if !c.photos.isEmpty {
                        ManageThumbStrip(items: c.photos.prefix(40).map { .init(id: $0) }, height: 72) { i in
                            viewer = PagerStart(list: PhotoList(ids: c.photos), index: i)
                        }
                    }
                    if rights.canWrite && c.count > 0 { actions(c) }
                    if c.accepted > 0 {
                        Button("Show the \(ManageAPI.plural(c.accepted, "accepted photo")) again") { Task { await unaccept(c.key) } }.font(.footnote)
                    }
                } header: { Text(c.title) }
            }
        }
        .navigationTitle("Metadata quality")
        .task { await rights.load(); await load() }
        .refreshable { await load() }
        .pager($viewer)
        .confirmationDialog(confirm == "files" ? "Clean up the image files too?" : "Remove the doubled face boxes?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirm == "files" ? "Clean up image files" : "Remove doubles", role: .destructive) {
                let files = confirm == "files"
                Task { await act("api/quality/fix", ["files": files]) { r in "Cleaning up \(ManageAPI.plural((r["photos"] as? NSNumber)?.intValue ?? 0, files ? "image file" : "photo")) in the background." } }
            }
        } message: { Text("One box is kept in each group of near-identical boxes; the sidecars are rewritten. A backup is taken first.") }
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
            Button("Ignore these unnamed faces") {
                Task { await act("api/quality/ignore", ["photos": c.photos]) { r in "\(ManageAPI.plural((r["ignored"] as? NSNumber)?.intValue ?? 0, "face")) ignored." } }
            }
            Button("Accept them as they are") { Task { await accept(c.key, c.photos) } }
        case "untagged", "nolocation", "wrongfolder", "baddate":
            Button("Accept these as they are") { Task { await accept(c.key, c.photos) } }
        default:
            EmptyView()
        }
    }

    private static let titles: [(String, String, String)] = [
        ("near", "Face boxes stored twice", "The same face marked twice, a little apart."),
        ("separate", "One person, two names", "The same person in two places of the tag tree."),
        ("invalid", "Boxes outside the photo", "Face boxes that stick out of their photo or are empty."),
        ("unnamed", "Unnamed faces", "Photos with faces found but not named."),
        ("untagged", "No tags", "Photos with no tag at all."),
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
                return Check(key: key, title: title, detail: detail, count: count, photos: photos, accepted: (s["accepted"] as? NSNumber)?.intValue ?? 0)
            }
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
    @State private var loaded = false
    @State private var viewer: PagerStart?
    @State private var notice: Notice?

    private static let actions: [(String, String)] = [("", "All changes"), ("edit", "Edits"), ("tag", "Tags"), ("face", "Faces"), ("moved", "Moved"),
                                                      ("trashed", "Trashed"), ("deleted", "Deleted"), ("added", "Added"), ("restore", "Restores")]
    private static let restoreLabels = ["undo": "Undo", "trash": "Restore from trash", "sidecar": "Put the sidecar back",
                                        "deleted": "Bring the photo back", "original": "Put the original file back"]

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $action) { ForEach(Self.actions, id: \.0) { Text($0.1).tag($0.0) } }
                if loaded { Text(ManageAPI.plural(total, "change")).font(.footnote).foregroundStyle(.secondary) }
            }
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        if let p = e.photo {
                            Button { viewer = PagerStart(list: PhotoList(ids: [p]), index: 0) } label: {
                                RemoteImage(path: "thumb/\(p)").frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 6))
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
            if loaded && entries.isEmpty { Text("No changes yet.").foregroundStyle(.secondary) }
        }
        .navigationTitle(photo == nil ? "History" : "This photo's history")
        .searchable(text: $search, prompt: "Search changes, file names, people")
        .onSubmit(of: .search) { sent = search }
        .onChange(of: search) { _, s in if s.isEmpty { sent = "" } }
        .task(id: "\(sent)|\(action)") { await rights.load(); await load(more: false) }
        .refreshable { await load(more: false) }
        .pager($viewer)
        .notice($notice)
    }

    private func load(more: Bool) async {
        var q = [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "offset", value: "\(more ? entries.count : 0)")]
        if !sent.isEmpty { q.append(URLQueryItem(name: "q", value: sent)) }
        if !action.isEmpty { q.append(URLQueryItem(name: "action", value: action)) }
        if let photo { q.append(URLQueryItem(name: "photo", value: "\(photo)")) }
        guard let j = try? await ManageAPI.get("api/history", q) else { loaded = true; return }
        total = (j["total"] as? NSNumber)?.intValue ?? 0
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
