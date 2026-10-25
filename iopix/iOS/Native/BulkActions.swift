import SwiftUI

/// A short message at the bottom of the screen, with an optional button (Undo), as the web app's toasts.
@MainActor
final class BulkToast: ObservableObject {
    static let shared = BulkToast()
    struct Message: Identifiable {
        let id = UUID()
        let text: String
        var action: (label: String, run: () async -> Void)? = nil
    }
    @Published var message: Message?
    private var hide: Task<Void, Never>?

    func show(_ text: String, seconds: Double = 4, action: (String, () async -> Void)? = nil) {
        let m = Message(text: text, action: action.map { (label: $0.0, run: $0.1) })
        message = m
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled, message?.id == m.id { message = nil }
        }
    }
}

/// Put once over a screen (`.overlay(alignment: .bottom) { BulkToastOverlay() }`).
struct BulkToastOverlay: View {
    @ObservedObject private var toast = BulkToast.shared

    var body: some View {
        if let m = toast.message {
            HStack(spacing: 14) {
                Text(m.text).font(.subheadline).foregroundStyle(.white).lineLimit(3)
                if let a = m.action {
                    Button(a.label) {
                        toast.message = nil
                        Task { await a.run() }
                    }
                    .font(.subheadline.bold()).foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.black.opacity(0.85), in: Capsule())
            .padding(.bottom, 90).padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(m.id)
        }
    }
}

/// What happened to the selection, for the grid to follow.
enum BulkOutcome {
    case changed            // metadata changed: load the list again
    case removed([Int])     // these left the list (trashed, moved out, taken out of the album)
}

/// The bar under a selection: everything the web app's selection bar does, the main actions as buttons and the rest
/// in a menu. Editing actions show only when this server and account allow them.
struct BulkActionBar: View {
    let ids: [Int]
    /// How many photos the list has (for "Select all N").
    let total: Int
    /// The album being shown, when the selection can be taken out of it.
    var album: Int? = nil
    var selectAll: () -> Void = {}
    var deselect: () -> Void = {}
    var done: (BulkOutcome) -> Void = { _ in }

    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var catalog = BulkCatalog.shared
    @State private var sheet: BulkSheet?
    @State private var confirmTrash = false
    @State private var sharing: [URL] = []
    @State private var preparing = false

    enum BulkSheet: String, Identifiable {
        case album, tags, edit, location, move, rename, copy, download, gpx, template
        var id: String { rawValue }
    }

    private var allFavorite: Bool { !ids.isEmpty && ids.allSatisfy { store.favoriteIDs.contains($0) } }
    private var albumEditable: Bool { album.map { a in catalog.albums.first { $0.id == a }?.canEdit ?? false } ?? false }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(ids.isEmpty ? "Select photos" : "\(ids.count.formatted()) selected").font(.subheadline.weight(.medium))
                Spacer()
                if ids.count < total { Button("Select all \(total.formatted())", action: selectAll).font(.subheadline) }
                if !ids.isEmpty { Button("Deselect", action: deselect).font(.subheadline) }
            }
            HStack(spacing: 0) {
                barButton(allFavorite ? "heart.fill" : "heart", allFavorite ? "Unfavorite" : "Favorite") {
                    Task {
                        if await store.setFavorites(ids, !allFavorite) {
                            BulkToast.shared.show(allFavorite ? "Removed from favorites." : "Added to favorites.")
                        } else { BulkToast.shared.show("Couldn't change your favorites.") }
                    }
                }
                barButton("rectangle.stack.badge.plus", "Add to album") { sheet = .album }
                if catalog.editing { barButton("tag", "Tag") { sheet = .tags } }
                barButton("square.and.arrow.up", "Share", busy: preparing) { Task { await share() } }
                if catalog.canManage { barButton("trash", "Trash", role: .destructive) { confirmTrash = true } }
                more
            }
            .disabled(ids.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .task { await catalog.load() }
        .sheet(item: $sheet) { s in sheetView(s) }
        .sheet(isPresented: Binding(get: { !sharing.isEmpty }, set: { if !$0 { cleanShared() } })) { ShareSheet(items: sharing) }
        .confirmationDialog(ids.count == 1 ? "Move this photo to the trash?" : "Move \(ids.count.formatted()) photos to the trash?",
                            isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Move to trash", role: .destructive) { Task { await trash() } }
        } message: { Text("They can be put back from Folders › Trash.") }
    }

    private var more: some View {
        Menu {
            if catalog.editing {
                Button { sheet = .edit } label: { Label("Edit rating, title, caption, date…", systemImage: "pencil") }
                Button { sheet = .location } label: { Label("Set location", systemImage: "mappin.and.ellipse") }
                Button { sheet = .template } label: { Label("Apply a metadata template", systemImage: "c.circle") }
                Button { sheet = .gpx } label: { Label("Correlate with a GPS track", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                if ids.count > 1 { Button { sheet = .copy } label: { Label("Copy metadata to the others", systemImage: "doc.on.doc") } }
            }
            if albumEditable {
                Button(role: .destructive) { Task { await removeFromAlbum() } } label: { Label("Remove from this album", systemImage: "minus.circle") }
            }
            Button { sheet = .download } label: { Label("Download as zip", systemImage: "arrow.down.circle") }
            if catalog.canManage {
                Button { sheet = .move } label: { Label("Move to a folder", systemImage: "folder") }
                Button { sheet = .rename } label: { Label("Rename by date", systemImage: "textformat") }
                if catalog.lossless {
                    Menu {
                        ForEach(Self.transforms, id: \.0) { op, label in
                            Button(label) { Task { await transform(op) } }
                        }
                    } label: { Label("Rotate or flip", systemImage: "rotate.right") }
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "ellipsis.circle").font(.title3)
                Text("More").font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
    }

    static let transforms = [("left", "Rotate left"), ("right", "Rotate right"), ("180", "Turn upside down"),
                             ("fliph", "Flip left to right"), ("flipv", "Flip top to bottom")]

    private func barButton(_ symbol: String, _ label: String, role: ButtonRole? = nil, busy: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                if busy { ProgressView().frame(height: 22) } else { Image(systemName: symbol).font(.title3) }
                Text(label).font(.caption2).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(busy)
        .accessibilityLabel(label)
    }

    @ViewBuilder private func sheetView(_ s: BulkSheet) -> some View {
        switch s {
        case .album: BulkAlbumSheet(ids: ids)
        case .tags: BulkTagSheet(ids: ids) { done(.changed) }
        case .edit: BulkEditSheet(ids: ids) { done(.changed) }
        case .location: BulkLocationSheet(ids: ids) { done(.changed) }
        case .template: BulkTemplateSheet(ids: ids) { done(.changed) }
        case .gpx: BulkGPXSheet(ids: ids) { done(.changed) }
        case .copy: BulkCopySheet(ids: ids) { done(.changed) }
        case .move: BulkMoveSheet(ids: ids) { moved in done(.removed(moved)) }
        case .rename: BulkRenameSheet(ids: ids) { done(.changed) }
        case .download: BulkDownloadSheet(query: PhotoQuery([("ids", ids.map(String.init).joined(separator: ","))]),
                                          title: "\(ids.count) selected photos")
        }
    }

    // MARK: actions done right here

    private func removeFromAlbum() async {
        guard let album else { return }
        do {
            try await BulkAPI.post("api/ualbums/\(album)", ["ids": ids, "on": false])
            await catalog.loadState()
            BulkToast.shared.show("Removed \(ids.count.formatted()) from the album.")
            done(.removed(ids))
        } catch { BulkToast.shared.show("Couldn't update the album: \(error.localizedDescription)") }
    }

    private func transform(_ op: String) async {
        do {
            let r = try await BulkAPI.post("api/photos/transform", ["ids": Array(ids.prefix(500)), "op": op])
            let failed = (r["failed"] as? [Any])?.count ?? 0
            for id in ids.prefix(500) {  // the pictures changed: their cached thumbnails are stale
                ImageCache.shared.forget("thumb/\(id)"); ImageCache.shared.forget("preview/\(id)")
            }
            var msg = failed > 0 ? "\(failed) couldn't be changed." : "Done. Each change is in the edit log with Undo."
            if ids.count > 500 { msg += " Only the first 500 were changed." }
            BulkToast.shared.show(msg, seconds: ids.count > 500 ? 8 : 4)
            done(.changed)
        } catch { BulkToast.shared.show(error.localizedDescription) }
    }

    /// Moves the selection to the trash in the background, with Undo while the message shows.
    private func trash() async {
        let chosen = ids
        do {
            let r = try await BulkAPI.post("api/photos/trash", ["ids": chosen, "background": true])
            done(.removed(chosen))
            guard let job = r["job"] as? String ?? (r["job"] as? NSNumber)?.stringValue else { return }
            let result = Task { () -> [String: Any]? in
                for _ in 0..<40 {
                    if let s = try? await IopixClient.shared.json("api/photos/trash/\(job)", query: [URLQueryItem(name: "wait", value: "25")]),
                       s["done"] as? Bool == true { return s }
                }
                return nil
            }
            BulkToast.shared.show(chosen.count == 1 ? "Photo moved to the trash." : "\(chosen.count.formatted()) photos moved to the trash.", seconds: 9,
                                  action: ("Undo", {
                guard let s = await result.value, let infos = s["infos"] as? [Any], !infos.isEmpty else {
                    BulkToast.shared.show("Nothing was moved, so there is nothing to put back."); return
                }
                do {
                    try await BulkAPI.post("api/trash/restore", ["infos": infos])
                    BulkToast.shared.show("Restored.")
                    done(.changed)
                } catch { BulkToast.shared.show(error.localizedDescription) }
            }))
            if let s = await result.value, let failed = s["failed"] as? [[String: Any]], let first = failed.first {
                BulkToast.shared.show("\(failed.count) couldn't be moved to the trash: \(first["error"] as? String ?? "")", seconds: 8)
                done(.changed)
            }
        } catch { BulkToast.shared.show(error.localizedDescription, seconds: 8) }
    }

    /// The originals, downloaded for the share sheet (at most 50 at a time; a zip download takes any number).
    private func share() async {
        preparing = true
        defer { preparing = false }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for id in ids.prefix(50) {
            guard let (tmp, resp) = try? await IopixClient.shared.session.download(for: IopixClient.shared.request("orig/\(id)")),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200 else { continue }
            let name = PhotoPager.filename(http) ?? "iopix-\(id).jpg"
            var dst = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dst.path) { dst = dir.appendingPathComponent("\(id)-\(name)") }
            if (try? FileManager.default.moveItem(at: tmp, to: dst)) != nil { out.append(dst) }
        }
        if out.isEmpty { BulkToast.shared.show("Couldn't get the photos to share.") }
        else {
            if ids.count > 50 { BulkToast.shared.show("Sharing the first 50. Use Download as zip for all of them.") }
            sharing = out
        }
    }

    private func cleanShared() {
        if let first = sharing.first { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        sharing = []
    }
}

// MARK: - albums

/// Add the selection to one of your albums, or to a new one (shared or just yours).
struct BulkAlbumSheet: View {
    let ids: [Int]
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var catalog = BulkCatalog.shared
    @State private var name = ""
    @State private var shared = true
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                let editable = catalog.albums.filter(\.canEdit)
                if !editable.isEmpty {
                    Section("Your albums") {
                        ForEach(editable) { a in
                            Button { Task { await add(a.id, a.name) } } label: {
                                HStack {
                                    Image(systemName: a.shared ? "rectangle.stack" : "lock").foregroundStyle(.secondary)
                                    Text(a.name).foregroundStyle(.primary)
                                    Spacer()
                                    Text(a.count.formatted()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if catalog.canShareAlbums || catalog.canPrivateAlbums {
                    Section("New album") {
                        TextField("Name", text: $name).onSubmit { Task { await add(nil, name) } }
                        if catalog.canShareAlbums && catalog.canPrivateAlbums {
                            Picker("Who sees it", selection: $shared) {
                                Text("Everyone").tag(true); Text("Only me").tag(false)
                            }
                        }
                        Button("Create and add") { Task { await add(nil, name) } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }
                } else {
                    Text("Sign in to make albums.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(ids.count == 1 ? "Add 1 photo to an album" : "Add \(ids.count.formatted()) photos to an album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { shared = catalog.canShareAlbums }
        }
    }

    private func add(_ id: Int?, _ label: String) async {
        guard !busy else { return }
        let n = label.trimmingCharacters(in: .whitespaces)
        if id == nil && n.isEmpty { return }
        busy = true
        defer { busy = false }
        do {
            if let id { try await BulkAPI.post("api/ualbums/\(id)", ["ids": ids, "on": true]) }
            else { try await BulkAPI.post("api/ualbums", ["name": n, "ids": ids, "shared": shared]) }
            await catalog.loadState()
            await store.load()
            BulkToast.shared.show("Added \(ids.count.formatted()) to “\(n)”.")
            dismiss()
        } catch {
            BulkToast.shared.show("Couldn't update the album: \(error.localizedDescription)")
        }
    }
}

// MARK: - folders, renaming

/// A folder of the library to move the selection into.
struct BulkMoveSheet: View {
    let ids: [Int]
    var moved: ([Int]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [(id: Int, path: String, all: Int)] = []
    @State private var filter = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                let f = filter.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                ForEach(folders.filter { f.isEmpty || $0.path.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(f) }.prefix(300), id: \.id) { x in
                    Button { Task { await move(to: x.id, path: x.path) } } label: {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(x.path).foregroundStyle(.primary)
                            Spacer()
                            if x.all > 0 { Text(x.all.formatted()).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(busy)
                }
            }
            .searchable(text: $filter, prompt: "Type part of a folder name")
            .navigationTitle(ids.count == 1 ? "Move 1 photo to…" : "Move \(ids.count.formatted()) photos to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        guard let d = try? await IopixClient.shared.json("api/folders") else { return }
        folders = (d["folders"] as? [[String: Any]] ?? []).compactMap { f in
            guard let id = (f["id"] as? NSNumber)?.intValue else { return nil }
            return (id, f["path"] as? String ?? "", (f["nAll"] as? NSNumber)?.intValue ?? 0)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func move(to id: Int, path: String) async {
        busy = true
        defer { busy = false }
        do {
            let r = try await BulkAPI.post("api/photos/move", ["ids": ids, "album": id])
            let movedIDs = (r["moved"] as? [Any] ?? []).compactMap { x -> Int? in
                if let n = (x as? NSNumber)?.intValue { return n }
                return ((x as? [String: Any])?["id"] as? NSNumber)?.intValue
            }
            let failed = r["failed"] as? [[String: Any]] ?? []
            var msg = "\(movedIDs.count == 1 ? "1 photo" : "\(movedIDs.count.formatted()) photos") moved to \(path)."
            if let first = failed.first { msg += " \(failed.count) couldn't be: \(first["error"] as? String ?? "")." }
            BulkToast.shared.show(msg, seconds: 8)
            moved(movedIDs)  // only what the server moved leaves the list; the rest stay where they are
            dismiss()
        } catch {
            BulkToast.shared.show(error.localizedDescription, seconds: 8)
        }
    }
}

/// Rename the files by the date they were taken; Undo puts the names back.
struct BulkRenameSheet: View {
    let ids: [Int]
    var changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pattern = "date"
    @State private var busy = false

    private static let examples = ["date": "2026-10-17_143205.jpg", "date-name": "2026-10-17_IMG_1234.jpg", "date-seq": "2026-10-17_001.jpg"]

    var body: some View {
        NavigationStack {
            Form {
                Picker("Name", selection: $pattern) {
                    Text("Date and time").tag("date"); Text("Date and original name").tag("date-name"); Text("Date and number").tag("date-seq")
                }
                .pickerStyle(.inline)
                Section {
                    Text("For example: \(Self.examples[pattern] ?? "")").foregroundStyle(.secondary)
                } footer: {
                    Text("The files are renamed in their folders, with their sidecars. Extensions stay. A name already taken gets -2, -3. digiKam sees the same files under their new names.")
                }
            }
            .navigationTitle(ids.count == 1 ? "Rename 1 file by date" : "Rename \(ids.count.formatted()) files by date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(busy ? "Renaming…" : "Rename") { Task { await rename() } }.disabled(busy) }
            }
        }
    }

    private func rename() async {
        busy = true
        defer { busy = false }
        do {
            let r = try await BulkAPI.post("api/photos/rename-pattern", ["ids": ids, "pattern": pattern])
            let renamed = r["renamed"] as? [[String: Any]] ?? []
            let failed = r["failed"] as? [[String: Any]] ?? []
            let unchanged = (r["unchanged"] as? NSNumber)?.intValue ?? 0
            var msg = "\(renamed.count == 1 ? "1 file" : "\(renamed.count.formatted()) files") renamed"
            if unchanged > 0 { msg += ", \(unchanged) already named so" }
            if let f = failed.first { msg += "; \(failed.count) not: \(f["error"] as? String ?? "")" }
            dismiss()
            changed()
            BulkToast.shared.show(msg + ".", seconds: 12, action: renamed.isEmpty ? nil : ("Undo", {
                var n = 0
                for x in renamed {
                    guard let id = (x["id"] as? NSNumber)?.intValue, let was = x["was"] as? String else { continue }
                    if (try? await BulkAPI.post("api/photos/rename", ["id": id, "name": was])) != nil { n += 1 }
                }
                BulkToast.shared.show("\(n == 1 ? "1 name" : "\(n) names") put back.")
                changed()
            }))
        } catch {
            BulkToast.shared.show(error.localizedDescription)
        }
    }
}
