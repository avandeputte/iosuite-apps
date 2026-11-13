import SwiftUI

/// What the editor sheet is open on: a new link or folder, or an existing one.
struct Draft: Identifiable {
    let id = UUID()
    var node: Node?
    var folder: Bool
    var parent: Int?
    var title = ""
    var url = ""
}

/// One folder of the tree (nil: the top level): its folders and links, search over everything, and the changes.
struct FolderView: View {
    @EnvironmentObject private var model: AppModel
    let folderID: Int?

    @State private var query = ""
    @State private var draft: Draft?
    @State private var deleting: Node?
    @State private var showSettings = false

    private var folder: Node? { folderID.flatMap { model.tree.node($0) } }
    private var items: [Node] { model.tree.children(of: folderID) }
    private var found: [Found] { model.tree.search(query) }
    private var mover: ((IndexSet, Int) -> Void)? {
        guard model.canWrite else { return nil }
        return { from, to in Task { await model.reorder(in: folderID, from: from, to: to) } }
    }

    var body: some View {
        List {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(found) { hit in
                    LinkRow(node: hit.node, detail: hit.path.isEmpty ? hit.node.host : hit.path)
                        .modifier(RowActions(node: hit.node, parent: nil, draft: $draft, deleting: $deleting))
                }
            } else {
                ForEach(items) { node in
                    Group {
                        if node.folder {
                            NavigationLink(value: node.id) { FolderRowView(node: node) }
                        } else {
                            LinkRow(node: node, detail: node.host)
                        }
                    }
                    .modifier(RowActions(node: node, parent: folderID, draft: $draft, deleting: $deleting))
                }
                .onMove(perform: mover)
            }
        }
        .listStyle(.plain)
        .overlay { emptyState }
        .navigationTitle(folderID == nil ? "Bookmarks" : (folder?.name ?? "Bookmarks"))
        .searchable(text: $query, prompt: "Search all bookmarks")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .refreshable { await model.refresh(quiet: false) }
        .toolbar {
            if folderID == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            if model.canWrite {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if items.count > 1 { EditButton() }
                    Menu {
                        Button { draft = Draft(folder: false, parent: folderID) } label: { Label("New bookmark", systemImage: "bookmark") }
                        Button { draft = Draft(folder: true, parent: folderID) } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                }
            }
        }
        .sheet(item: $draft) { NodeEditor(draft: $0) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .confirmationDialog(deleteQuestion, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let node = deleting { Task { await model.delete(node) } }
            }
        } message: {
            Text("It goes from the start page and from every browser that syncs with it.")
        }
    }

    private var deleteQuestion: String {
        guard let node = deleting else { return "" }
        if node.folder {
            let n = node.kids.linkCount
            return n == 0 ? "Delete the folder “\(node.name)”?" : "Delete the folder “\(node.name)” and the \(n) bookmark\(n == 1 ? "" : "s") in it?"
        }
        return "Delete “\(node.name)”?"
    }

    @ViewBuilder private var emptyState: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            if found.isEmpty { ContentUnavailableView.search(text: query) }
        } else if items.isEmpty {
            if model.loaded {
                ContentUnavailableView("Nothing here yet", systemImage: "bookmark", description: Text(model.canWrite ? "Add a bookmark with +, or share a page to ioStart from your browser." : "This folder is empty."))
            } else {
                ProgressView()
            }
        }
    }
}

private struct FolderRowView: View {
    let node: Node

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
            Text(node.name).lineLimit(1)
            Spacer()
            Text("\(node.kids.count)").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct LinkRow: View {
    @EnvironmentObject private var model: AppModel
    let node: Node
    let detail: String?

    var body: some View {
        Button { model.open(node) } label: {
            HStack(spacing: 12) {
                SiteIcon(node: node)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).foregroundStyle(.primary).lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Swipes and the long-press menu of a row.
private struct RowActions: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let node: Node
    /// The folder the row is shown in; nil in search results, where it is looked up.
    let parent: Int?
    @Binding var draft: Draft?
    @Binding var deleting: Node?

    private var home: Int? { parent ?? (model.tree.parent(of: node.id) ?? nil) }

    private func edit() {
        draft = Draft(node: node, folder: node.folder, parent: home, title: node.title, url: node.url ?? "")
    }

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if model.canWrite {
                    Button(role: .destructive) { deleting = node } label: { Label("Delete", systemImage: "trash") }
                    Button { edit() } label: { Label("Edit", systemImage: "pencil") }.tint(.indigo)
                }
            }
            .contextMenu {
                if let url = node.link {
                    Button { model.open(url, in: .app) } label: { Label("Open here", systemImage: "rectangle.portrait.and.arrow.right") }
                    Button { model.open(url, in: .browser) } label: { Label("Open in my browser", systemImage: "safari") }
                    Button { UIPasteboard.general.url = url } label: { Label("Copy address", systemImage: "doc.on.doc") }
                    ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                }
                if model.canWrite {
                    Divider()
                    Button { edit() } label: { Label(node.folder ? "Rename or move" : "Edit or move", systemImage: "pencil") }
                    Button(role: .destructive) { deleting = node } label: { Label("Delete", systemImage: "trash") }
                }
            }
    }
}
