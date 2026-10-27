import SwiftUI

/// Every tag in the library as the server lists them (people too, marked), for the Tags page.
@MainActor
final class TagTree: ObservableObject {
    struct Node: Identifiable, Hashable {
        let id: Int
        let pid: Int?
        let name: String
        let full: String
        let person: Bool
        let n: Int
        let nAll: Int
        let cover: Int?
    }
    @Published var nodes: [Node] = []
    @Published var loaded = false
    @Published var problem: String?

    func load() async {
        do {
            let m = try await ManageAPI.get("api/meta")
            nodes = (m["tags"] as? [[String: Any]] ?? []).compactMap { t in
                guard let id = (t["id"] as? NSNumber)?.intValue else { return nil }
                return Node(id: id, pid: (t["pid"] as? NSNumber)?.intValue, name: (t["name"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                            full: t["full"] as? String ?? "", person: (t["person"] as? NSNumber)?.boolValue ?? false,
                            n: (t["n"] as? NSNumber)?.intValue ?? 0, nAll: (t["nAll"] as? NSNumber)?.intValue ?? 0,
                            cover: (t["cover"] as? NSNumber)?.intValue)
            }
            .filter { !Self.isFaceBucket($0) && !$0.name.hasPrefix("_") }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    /// digiKam's own face buckets under People: not tags to manage.
    static func isFaceBucket(_ t: Node) -> Bool { ["Unknown", "Ignored", "Unconfirmed"].contains(t.name) && t.full.hasPrefix("People/") }

    func children(of parent: Int?) -> [Node] {
        let ids = Set(nodes.map(\.id))
        return nodes.filter { parent == nil ? ($0.pid == nil || !ids.contains($0.pid!)) : $0.pid == parent }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func node(_ id: Int?) -> Node? { id.flatMap { i in nodes.first { $0.id == i } } }

    func subtree(_ id: Int) -> Set<Int> {
        var out: Set<Int> = [id], grew = true
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

/// The tags: browse and open their photos; editors add, rename, move, merge and delete tags (digiKam's database is
/// changed, so digiKam has to be closed).
struct ManageTagsScreen: View {
    let parent: Int?
    var tree: TagTree? = nil
    @StateObject private var ownTree = TagTree()
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var rights = ManageRights()
    @State private var adding = false
    @State private var addName = ""
    @State private var renaming: TagTree.Node?
    @State private var renameText = ""
    @State private var moving: TagTree.Node?
    @State private var merging: TagTree.Node?
    @State private var mergeInto: (TagTree.Node, TagTree.Node)?
    @State private var deleting: TagTree.Node?
    @State private var search = ""
    @State private var notice: Notice?

    init(parent: Int? = nil, tree: TagTree? = nil) {
        self.parent = parent
        self.tree = tree
    }

    private var t: TagTree { tree ?? ownTree }

    var body: some View {
        let here = t.node(parent)
        let subs = search.isEmpty ? t.children(of: parent)
            : t.nodes.filter { $0.name.localizedCaseInsensitiveContains(search) }.sorted { $0.nAll > $1.nAll }
        List {
            if let problem = t.problem { Text(problem).foregroundStyle(.secondary) }
            if let here, search.isEmpty {
                NavigationLink {
                    PhotoGridScreen(query: PhotoQuery([("tag", "\(here.id)")]), title: here.name)
                } label: {
                    ThumbRow(cover: here.cover, title: "All photos tagged \(here.name)", sub: here.nAll.formatted(), symbol: "tag")
                }
            }
            ForEach(subs) { tag in
                NavigationLink {
                    if t.children(of: tag.id).isEmpty {
                        PhotoGridScreen(query: PhotoQuery([("tag", "\(tag.id)")]), title: tag.name)
                    } else {
                        ManageTagsScreen(parent: tag.id, tree: t)
                    }
                } label: {
                    ThumbRow(cover: tag.cover, title: tag.name, sub: (search.isEmpty ? "" : tag.full + " · ") + (tag.nAll == 0 ? "No photos" : tag.nAll.formatted()),
                             symbol: tag.person ? "person" : "tag")
                }
                .swipeActions(edge: .trailing) {
                    if rights.canWrite {
                        if !tag.person { Button("Delete", role: .destructive) { deleting = tag } }
                        Button("Rename") { renameText = tag.name; renaming = tag }.tint(Hue.blue)
                        Button("Move") { moving = tag }.tint(Hue.indigo)
                    }
                }
                .contextMenu { if rights.canWrite { menu(tag) } }
            }
            if t.loaded && subs.isEmpty && here == nil {
                Text(search.isEmpty ? "No tags yet." : "No tag called “\(search)”.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(here?.name ?? "Tags")
        .searchable(text: $search, prompt: "Find a tag")
        .toolbar {
            if rights.canWrite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { addName = ""; adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(here == nil ? "New tag" : "New tag inside \(here!.name)")
                }
            }
        }
        .task {
            await rights.load()
            if tree == nil, !t.loaded { await t.load() }
        }
        .refreshable { await t.load() }
        .namePrompt(here == nil ? "New tag" : "New tag inside “\(here!.name)”", isPresented: $adding, text: $addName, action: "Add") { name in
            Task { await op(["op": "add", "parent": parent ?? 0, "name": name], "Tag “\(name)” added.") }
        }
        .namePrompt("Rename tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), text: $renameText,
                    message: "Photos keep the tag under its new name; their sidecars are updated.") { name in
            if let tag = renaming { Task { await op(["op": "rename", "id": tag.id, "name": name], "Renamed to “\(name)”.") } }
        }
        .sheet(item: $moving) { tag in
            TagPicker(tree: t, excluding: t.subtree(tag.id), allowTop: true, title: "Move “\(tag.name)” into") { target in
                Task { await op(["op": "move", "id": tag.id, "parent": target ?? 0], "Moved.") }
            }
        }
        .sheet(item: $merging) { tag in
            TagPicker(tree: t, excluding: t.subtree(tag.id), allowTop: false, title: "Merge “\(tag.name)” into") { target in
                if let target, let into = t.node(target) { mergeInto = (tag, into) }
            }
        }
        .confirmationDialog("Merge “\(mergeInto?.0.name ?? "")” into “\(mergeInto?.1.name ?? "")”?", isPresented: Binding(get: { mergeInto != nil }, set: { if !$0 { mergeInto = nil } }), titleVisibility: .visible) {
            Button("Merge", role: .destructive) {
                if let (tag, into) = mergeInto { Task { await op(["op": "merge", "id": tag.id, "into": into.id], "Merged “\(tag.name)” into “\(into.name)”.") } }
            }
        } message: { Text("Its \(ManageAPI.plural(mergeInto?.0.nAll ?? 0, "photo")) and face boxes move to “\(mergeInto?.1.name ?? "")”, then “\(mergeInto?.0.name ?? "")” is removed. A backup of digiKam's database is taken first.") }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete tag", role: .destructive) {
                if let tag = deleting { Task { await op(["op": "delete", "id": tag.id], "Tag deleted.") } }
            }
        } message: { Text("The tag comes off \(ManageAPI.plural(deleting?.nAll ?? 0, "photo")), tags inside it too. The photos stay. A backup of digiKam's database is taken first.") }
        .notice($notice)
    }

    @ViewBuilder private func menu(_ tag: TagTree.Node) -> some View {
        Button { renameText = tag.name; renaming = tag } label: { Label("Rename…", systemImage: "pencil") }
        Button { moving = tag } label: { Label("Move…", systemImage: "arrow.turn.down.right") }
        Button { merging = tag } label: { Label("Merge into…", systemImage: "arrow.triangle.merge") }
        if tag.person {
            Button { Task { await op(["op": "notperson", "id": tag.id], "“\(tag.name)” is a keyword tag again.") } } label: {
                Label("Not a person", systemImage: "person.slash")
            }
        } else {
            Button { Task { await op(["op": "person", "id": tag.id], "“\(tag.name)” is a person now.") } } label: {
                Label("Mark as a person", systemImage: "person.badge.plus")
            }
            Button(role: .destructive) { deleting = tag } label: { Label("Delete…", systemImage: "trash") }
        }
    }

    private func op(_ body: [String: Any], _ ok: String) async {
        do {
            let r = try await ManageAPI.post("api/tags/op", body)
            var text = ok
            if let n = (r["photos"] as? NSNumber)?.intValue, n > 0, (r["sidecars"] as? NSNumber)?.intValue ?? 0 > 0 {
                text += " Updating \(ManageAPI.plural(n, "photo"))’s sidecars in the background."
            }
            notice = Notice(text: text)
            try? await Task.sleep(nanoseconds: 800_000_000)  // the library summary catches up
            await t.load()
            await store.load()
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }
}

/// Picks a tag (to move or merge into); the top level when `allowTop`.
struct TagPicker: View {
    @ObservedObject var tree: TagTree
    let excluding: Set<Int>
    let allowTop: Bool
    let title: String
    let chosen: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            List {
                if allowTop && filter.isEmpty {
                    Button { chosen(nil); dismiss() } label: { Label("Top level", systemImage: "square.stack.3d.up") }.tint(.primary)
                }
                ForEach(ordered()) { n in
                    Button { chosen(n.id); dismiss() } label: {
                        HStack {
                            Image(systemName: n.person ? "person" : "tag").foregroundStyle(.secondary)
                            Text(filter.isEmpty ? n.name : n.full)
                        }
                        .padding(.leading, CGFloat(filter.isEmpty ? tree.depth(n) * 16 : 0))
                    }
                    .tint(.primary)
                }
            }
            .searchable(text: $filter, prompt: "Find a tag")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { BarText("Cancel") } } }
        }
    }

    private func ordered() -> [TagTree.Node] {
        if !filter.isEmpty {
            return tree.nodes.filter { !excluding.contains($0.id) && $0.full.localizedCaseInsensitiveContains(filter) }
                .sorted { $0.full.localizedStandardCompare($1.full) == .orderedAscending }
        }
        var out: [TagTree.Node] = []
        func walk(_ p: Int?) {
            for n in tree.children(of: p) where !excluding.contains(n.id) { out.append(n); walk(n.id) }
        }
        walk(nil)
        return out
    }
}
