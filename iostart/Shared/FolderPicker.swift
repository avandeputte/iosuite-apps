import SwiftUI

/// Picks the folder a bookmark goes in: the top level, or any folder of the tree.
struct FolderPicker: View {
    let tree: [Node]
    /// A folder being moved: it and what is in it cannot be picked.
    var without: Int?
    @Binding var selection: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            row(id: nil, name: "Top level", depth: 0, symbol: "tray.full")
            ForEach(tree.folders(without: without)) { f in
                row(id: f.node.id, name: f.node.name, depth: f.depth, symbol: "folder")
            }
        }
        .navigationTitle("Folder")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(id: Int?, name: String, depth: Int, symbol: String) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.tint).frame(width: 24)
                Text(name).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                if selection == id { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .padding(.leading, CGFloat(depth) * 18)
        }
    }
}

/// The name of a folder for a form row ("Top level" for nil or a folder that is gone).
func folderName(_ id: Int?, in tree: [Node]) -> String {
    guard let id, let n = tree.node(id) else { return "Top level" }
    return n.name
}
