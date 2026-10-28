import SwiftUI
import PhotosUI

/// digiKam's folders as the server lists them (empty ones too), with what editors may do to them.
@MainActor
final class FolderTree: ObservableObject {
    struct Node: Identifiable, Hashable {
        let id: Int
        let pid: Int?
        let name: String
        let root: Int
        let path: String
        var caption: String
        var date: String
        var category: String
        /// The cover photo chosen for it (digiKam's album icon); nil for the automatic one.
        var icon: Int?
        let n: Int
        let nAll: Int
    }

    @Published var nodes: [Node] = []
    @Published var canManage = false
    @Published var problem: String?
    @Published var loaded = false

    func load() async {
        do {
            let j = try await ManageAPI.get("api/folders")
            canManage = j["canManage"] as? Bool ?? false
            nodes = (j["folders"] as? [[String: Any]] ?? []).compactMap { f in
                guard let id = (f["id"] as? NSNumber)?.intValue else { return nil }
                return Node(id: id, pid: (f["pid"] as? NSNumber)?.intValue, name: f["name"] as? String ?? "",
                            root: (f["root"] as? NSNumber)?.intValue ?? 0, path: f["path"] as? String ?? "",
                            caption: f["caption"] as? String ?? "", date: f["date"] as? String ?? "",
                            category: f["category"] as? String ?? "", icon: (f["icon"] as? NSNumber)?.intValue,
                            n: (f["n"] as? NSNumber)?.intValue ?? 0, nAll: (f["nAll"] as? NSNumber)?.intValue ?? 0)
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    func children(of parent: Int?) -> [Node] {
        let ids = Set(nodes.map(\.id))
        return nodes.filter { parent == nil ? ($0.pid == nil || !ids.contains($0.pid!)) : $0.pid == parent }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func node(_ id: Int?) -> Node? { id.flatMap { i in nodes.first { $0.id == i } } }

    /// The folder and everything below it (a folder can't be moved into itself).
    func subtree(_ id: Int) -> Set<Int> {
        var out: Set<Int> = [id]
        var grew = true
        while grew {
            grew = false
            for n in nodes where n.pid.map(out.contains) == true && !out.contains(n.id) { out.insert(n.id); grew = true }
        }
        return out
    }

    func depth(_ n: Node) -> Int {
        var d = 0, p = n.pid
        while let q = p, d < 40, let up = node(q) { d += 1; p = up.pid }
        return d
    }
}

/// The folders on disk: browse them, open their photos, and (for editors) make, rename and move folders, edit their
/// caption, date and collection, and upload photos from this device into one.
struct ManageFoldersScreen: View {
    let parent: Int?
    @StateObject private var ownTree = FolderTree()
    var tree: FolderTree? = nil
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var rights = ManageRights()
    @State private var picked: [PhotosPickerItem] = []
    @State private var uploading = false
    @State private var newFolder = false
    @State private var newName = ""
    @State private var renaming: FolderTree.Node?
    @State private var renameText = ""
    @State private var moving: FolderTree.Node?
    @State private var editing: FolderTree.Node?
    @State private var detecting: FolderTree.Node?
    /// Face detection is available on this server (the status' faceDetect).
    @State private var faceDetect = false
    @State private var filter = ""
    @State private var notice: Notice?

    init(parent: Int? = nil, tree: FolderTree? = nil) {
        self.parent = parent
        self.tree = tree
    }

    private var t: FolderTree { tree ?? ownTree }
    /// The server's canManage says the library can be changed; only editors may do it (the server refuses others).
    private var canManage: Bool { t.canManage && rights.canWrite }

    var body: some View {
        let here = t.node(parent)
        let subs = t.children(of: parent)
        List {
            if let problem = t.problem { Text(problem).foregroundStyle(.secondary) }
            if parent == nil, !filter.trimmingCharacters(in: .whitespaces).isEmpty {
                // the find box: every folder whose path matches, flat, as the web app lists them
                let found = t.nodes.filter { $0.path.localizedStandardContains(filter.trimmingCharacters(in: .whitespaces)) }
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                ForEach(found) { f in
                    NavigationLink {
                        if f.nAll > 0 || t.children(of: f.id).isEmpty {
                            PhotoGridScreen(query: PhotoQuery([("album", "\(f.id)")]), title: f.name)
                        } else {
                            ManageFoldersScreen(parent: f.id, tree: t)
                        }
                    } label: {
                        ThumbRow(cover: cover(f.id), title: f.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: " › "),
                                 sub: f.nAll == 0 ? "Empty" : f.nAll.formatted(), symbol: "folder")
                    }
                }
                if found.isEmpty { Text("No folders match.").foregroundStyle(.secondary) }
            } else {
            if let here {
                if !here.caption.isEmpty || !here.category.isEmpty {
                    Section {
                        if !here.caption.isEmpty { Text(here.caption) }
                        if !here.category.isEmpty { Label(here.category, systemImage: "square.stack") .font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                NavigationLink {
                    PhotoGridScreen(query: PhotoQuery([("album", "\(here.id)")]), title: here.name)
                } label: {
                    ThumbRow(cover: cover(here.id), title: "All photos in \(here.name)", sub: here.nAll.formatted(), symbol: "photo.stack")
                }
            }
            ForEach(subs) { f in
                NavigationLink {
                    if t.children(of: f.id).isEmpty {
                        PhotoGridScreen(query: PhotoQuery([("album", "\(f.id)")]), title: f.name)
                    } else {
                        ManageFoldersScreen(parent: f.id, tree: t)
                    }
                } label: {
                    ThumbRow(cover: cover(f.id), title: f.name, sub: f.nAll == 0 ? "Empty" : f.nAll.formatted(), symbol: "folder")
                }
                .swipeActions(edge: .trailing) {
                    if canManage && f.pid != nil {
                        Button("Rename") { renameText = f.name; renaming = f }.tint(Hue.blue)
                        Button("Move") { moving = f }.tint(Hue.indigo)
                        Button("Info") { editing = f }.tint(Hue.slate)
                    }
                }
                .contextMenu {
                    if canManage && f.pid != nil {
                        Button { renameText = f.name; renaming = f } label: { Label("Rename…", systemImage: "pencil") }
                        Button { moving = f } label: { Label("Move…", systemImage: "folder.badge.gearshape") }
                        Button { editing = f } label: { Label("Caption, date, collection and cover…", systemImage: "info.circle") }
                        if f.nAll > 0 && faceDetect {
                            Button { detecting = f } label: { Label("Detect faces in this folder", systemImage: "face.dashed") }
                        }
                    }
                }
            }
            if t.loaded && subs.isEmpty && here == nil {
                Text("No folders.").foregroundStyle(.secondary)
            }
            }
        }
        .modifier(FindFolders(on: parent == nil, text: $filter))
        .overlay { if uploading { ProgressView("Uploading…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .navigationTitle(here?.name ?? "Folders")
        .toolbar {
            if canManage {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { newName = ""; newFolder = true } label: { Label("New folder…", systemImage: "folder.badge.plus") }
                            .disabled(parent == nil && t.children(of: nil).isEmpty)
                        if let here {
                            PhotosPicker(selection: $picked, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                                Label("Upload photos here…", systemImage: "square.and.arrow.up")
                            }
                            Button { editing = here } label: { Label("Caption, date, collection and cover…", systemImage: "info.circle") }
                            if here.nAll > 0 && faceDetect {
                                Button { detecting = here } label: { Label("Detect faces in this folder", systemImage: "face.dashed") }
                            }
                            if here.pid != nil {
                                Button { renameText = here.name; renaming = here } label: { Label("Rename…", systemImage: "pencil") }
                                Button { moving = here } label: { Label("Move…", systemImage: "folder.badge.gearshape") }
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .task {
            await rights.load()
            if tree == nil, !t.loaded { await t.load() }
            faceDetect = ((try? await ManageAPI.get("api/status"))?["faceDetect"] as? Bool) ?? false
        }
        .refreshable { await t.load(); await store.load() }
        .namePrompt("New folder", isPresented: $newFolder, text: $newName, action: "Create",
                    message: "Inside \(here?.name ?? t.children(of: nil).first?.name ?? "the library").") { name in
            Task { await create(name) }
        }
        .namePrompt("Rename folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), text: $renameText,
                    message: "The folder is renamed on disk too.") { name in
            if let f = renaming { Task { await act("api/folders/\(f.id)/rename", ["name": name], "Renamed to “\(name)”.") } }
        }
        .sheet(item: $moving) { f in
            FolderPicker(tree: t, excluding: t.subtree(f.id), root: f.root, title: "Move “\(f.name)” into") { target in
                Task { await act("api/folders/\(f.id)/move", ["parent": target], "Moved.") }
            }
        }
        .sheet(item: $editing) { f in
            FolderPropertiesSheet(folder: f) { caption, date, category, icon in
                Task { await act("api/folders/\(f.id)/properties", ["caption": caption, "date": date, "category": category, "icon": icon ?? NSNull()], "Folder properties saved.") }
            }
        }
        .confirmationDialog("Look for faces in the \(ManageAPI.plural(detecting?.nAll ?? 0, "photo")) of “\(detecting?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? "")” (with its subfolders)?",
                            isPresented: Binding(get: { detecting != nil }, set: { if !$0 { detecting = nil } }), titleVisibility: .visible) {
            Button("Look for faces") { if let f = detecting { Task { await detectFaces(f) } } }
        } message: { Text("New faces are added as unnamed faces; faces already marked stay as they are.") }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty, let here else { return }
            picked = []
            Task { await upload(items, into: here) }
        }
        .notice($notice)
    }

    private func cover(_ id: Int) -> Int? { store.folders.first { $0.id == id }?.cover }

    /// Face detection over a folder and its subfolders: the server runs it in the background.
    private func detectFaces(_ f: FolderTree.Node) async {
        do {
            let r = try await ManageAPI.post("api/faces/detect", ["album": f.id])
            if r["done"] as? Bool == true {
                let added = (r["added"] as? NSNumber)?.intValue ?? 0, found = (r["found"] as? NSNumber)?.intValue ?? 0
                notice = Notice(text: added > 0 ? "Found \(ManageAPI.plural(added, "new face")). Name \(added == 1 ? "it" : "them") under People."
                                : found > 0 ? "No new faces: the \(ManageAPI.plural(found, "face")) found \(found == 1 ? "is" : "are") already marked." : "No faces found.")
            } else {
                notice = Notice(text: "Looking for faces in \(ManageAPI.plural((r["queued"] as? NSNumber)?.intValue ?? 0, "photo")) in the background; progress in Maintenance › AI analysis and models.")
            }
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }

    private func create(_ name: String) async {
        let into = parent ?? t.children(of: nil).first?.id ?? 0
        await act("api/folders", ["parent": into, "name": name], "Folder “\(name)” made.")
    }

    private func act(_ path: String, _ body: [String: Any], _ ok: String) async {
        do {
            _ = try await ManageAPI.post(path, body)
            notice = Notice(text: ok)
            await t.load()
            await store.load()
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }

    private func upload(_ items: [PhotosPickerItem], into folder: FolderTree.Node) async {
        uploading = true
        defer { uploading = false }
        let files = await ManageAPI.files(from: items)
        defer { ManageAPI.cleanUp(files) }
        guard !files.isEmpty else { notice = Notice(text: "Couldn't read the photos picked.", failed: true); return }
        do {
            let r = try await ManageAPI.upload("api/folders/\(folder.id)/upload", files: files)
            let added = (r["added"] as? [Any])?.count ?? 0
            let skipped = (r["skipped"] as? [[String: Any]] ?? []).map { "\($0["name"] as? String ?? ""): \($0["reason"] as? String ?? "skipped")" }
            var text = "\(ManageAPI.plural(added, "file")) uploaded into \(folder.name)."
            if added > 0 { text += " digiKam reads them fully on its next start." }
            if !skipped.isEmpty { text += " Not uploaded: " + skipped.joined(separator: "; ") }
            notice = Notice(text: text, failed: added == 0)
            await t.load()
            await store.load()
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }
}

/// The find box, on the top-level list only (as the web app's Folders page has it).
private struct FindFolders: ViewModifier {
    let on: Bool
    @Binding var text: String
    func body(content: Content) -> some View {
        if on { content.searchable(text: $text, prompt: "Find a folder…") } else { content }
    }
}

/// Picks a folder of the same album root (to move something into).
struct FolderPicker: View {
    @ObservedObject var tree: FolderTree
    let excluding: Set<Int>
    let root: Int
    let title: String
    let chosen: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(ordered()) { n in
                    Button {
                        chosen(n.id)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(n.pid == nil ? "\(n.name) (top)" : n.name)
                        }
                        .padding(.leading, CGFloat(filter.isEmpty ? tree.depth(n) * 16 : 0))
                    }
                    .tint(.primary)
                }
            }
            .searchable(text: $filter, prompt: "Find a folder")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Cancel") } } }
        }
    }

    /// Depth-first, so each folder sits under its parent.
    private func ordered() -> [FolderTree.Node] {
        var out: [FolderTree.Node] = []
        func walk(_ parent: Int?) {
            for n in tree.children(of: parent) where n.root == root && !excluding.contains(n.id) {
                if filter.isEmpty || n.name.localizedCaseInsensitiveContains(filter) { out.append(n) }
                walk(n.id)
            }
        }
        walk(nil)
        return out
    }
}

/// digiKam's folder properties: caption, date, collection and cover (one of the folder's photos, or the best-rated
/// one chosen automatically).
struct FolderPropertiesSheet: View {
    let folder: FolderTree.Node
    let save: (String, String, String, Int?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var caption = ""
    @State private var date = Date()
    @State private var category = ""
    @State private var icon: Int?
    @State private var covers: [Int]?

    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section("Caption") { TextField("What this folder holds", text: $caption, axis: .vertical).lineLimit(2...6) }
                Section("Date") { DatePicker("Date", selection: $date, displayedComponents: .date).environment(\.timeZone, TimeZone(identifier: "UTC")!) }
                Section { TextField("Collection", text: $category) } header: { Text("Collection") } footer: {
                    Text("digiKam's collection name, used to group folders.")
                }
                Section("Cover") {
                    if let covers {
                        if covers.isEmpty {
                            Text("This folder has no photos yet.").foregroundStyle(.secondary)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    coverChoice(nil) {
                                        Text("Auto").font(.caption).frame(width: 72, height: 72).background(Color.secondary.opacity(0.12))
                                    }
                                    ForEach(covers, id: \.self) { id in
                                        coverChoice(id) { RemoteImage(path: "thumb/\(id)").frame(width: 72, height: 72).clipped() }
                                    }
                                }
                            }
                            Text("Auto: the best-rated photo.").font(.footnote).foregroundStyle(.secondary)
                        }
                    } else { ProgressView() }
                }
            }
            .navigationTitle(folder.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Cancel") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save(caption, Self.format.string(from: date), category, icon)
                        dismiss()
                    } label: { BarText("Save") }
                }
            }
            .onAppear {
                caption = folder.caption
                category = folder.category
                icon = folder.icon
                if let d = Self.format.date(from: folder.date) { date = d }
            }
            .task {
                // the first 80 photos of the folder, oldest first, as the web app offers them
                let l = try? await PhotoList.load([URLQueryItem(name: "album", value: "\(folder.id)"), URLQueryItem(name: "sort", value: "old")])
                covers = Array((l?.ids ?? []).prefix(80))
            }
        }
    }

    private func coverChoice<V: View>(_ id: Int?, @ViewBuilder _ label: () -> V) -> some View {
        Button { icon = id } label: {
            label()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: icon == id ? 3 : 0))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(id == nil ? "Chosen automatically" : "Photo \(id ?? 0)")
    }
}
