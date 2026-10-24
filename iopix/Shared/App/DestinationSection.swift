import SwiftUI

/// Settings › Folder in iopix: where uploads go.
struct DestinationSection: View {
    @EnvironmentObject private var queue: UploadQueue
    @State private var dest = Destination.current
    @State private var layouts: [ServerLayout] = []
    @State private var patterns: Bool?

    var body: some View {
        Section {
            Picker("Put photos in", selection: $dest.kind) {
                Text("Folders by date").tag(Destination.Kind.layout)
                Text("Folders named my way").tag(Destination.Kind.pattern)
                Text("One folder").tag(Destination.Kind.folder)
            }
            switch dest.kind {
            case .layout:
                Picker("Layout", selection: $dest.layout) {
                    if layouts.isEmpty { Text("2026/202610").tag(dest.layout) }
                    else if !layouts.contains(where: { $0.key == dest.layout }) { Text(dest.layout).tag(dest.layout) }  // a layout this server no longer offers
                    ForEach(layouts) { Text($0.example).tag($0.key) }
                }
            case .pattern:
                TextField("Folder pattern", text: $dest.pattern, prompt: Text("{yyyy}/{yyyy}{mm}"))
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                Text("{yyyy}, {mm} and {dd} stand for the year, month and day the photo was taken. Use / for a folder inside another.")
                    .font(.caption).foregroundStyle(.secondary)
            case .folder:
                TextField("Folder", text: $dest.folder, prompt: Text("Upload"))
                    #if os(iOS)
                    .autocorrectionDisabled()
                    #endif
            }
            LabeledContent("A photo taken today goes to") {
                Text(dest.example(layouts: layouts).isEmpty ? "—" : dest.example(layouts: layouts)).foregroundStyle(.secondary)
            }
            if dest.needsPatterns && patterns == false {
                Text("Your iopix server needs an update before it can do this. Until then photos wait in the queue.")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Folder in iopix")
        } footer: {
            Text("Folders that don't exist yet are created in iopix.").font(.caption).foregroundStyle(.secondary)
        }
        .task { await loadLayouts() }
        .onChange(of: dest) { _, d in
            Destination.current = d
            queue.kick()
        }
    }

    private func loadLayouts() async {
        guard let r = try? await IopixClient.shared.layouts() else { return }
        layouts = r.layouts
        patterns = r.patterns
    }
}
