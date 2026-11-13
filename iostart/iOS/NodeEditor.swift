import SwiftUI

/// A new bookmark or folder, or an existing one: its name, address and the folder it is in.
struct NodeEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Draft
    @State private var saving = false
    @FocusState private var focus: Field?

    private enum Field { case title, url }

    init(draft: Draft) {
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { draft.node == nil }
    private var address: String { tidyAddress(draft.url) }
    private var usable: Bool {
        draft.folder ? !draft.title.trimmingCharacters(in: .whitespaces).isEmpty : !address.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !draft.folder {
                        TextField("Address", text: $draft.url, axis: .vertical)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .url)
                    }
                    TextField(draft.folder ? "Name" : "Name (the site's, when left empty)", text: $draft.title)
                        .focused($focus, equals: .title)
                }
                Section {
                    NavigationLink {
                        FolderPicker(tree: model.tree, without: draft.folder ? draft.node?.id : nil, selection: $draft.parent)
                    } label: {
                        LabeledContent("Folder", value: folderName(draft.parent, in: model.tree))
                    }
                }
            }
            .navigationTitle(isNew ? (draft.folder ? "New folder" : "New bookmark") : (draft.folder ? "Folder" : "Bookmark"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") { Task { await save() } }.disabled(!usable || saving)
                }
            }
            .onAppear {
                if isNew { focus = draft.folder || !draft.url.isEmpty ? .title : .url }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var done = true
        if let node = draft.node {
            var ops: [Op] = []
            let newURL = draft.folder ? nil : address
            if title != node.title || (newURL != nil && newURL != node.url) {
                ops.append(.update(node.id, title: title, url: newURL))
            }
            let was = model.tree.parent(of: node.id) ?? nil
            if draft.parent != was {
                ops.append(.order(parent: draft.parent, ids: [node.id]))  // named from elsewhere: it moves in, at the end
            }
            if !ops.isEmpty { done = await model.send(ops) }
        } else {
            let name = title.isEmpty && !draft.folder ? (URL(string: address)?.host ?? "") : title
            done = await model.add(folder: draft.folder, title: name, url: draft.folder ? nil : address, to: draft.parent)
        }
        if done { dismiss() }
    }
}
