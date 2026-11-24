import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The ioPix window: what is being sent, and a place to drop photos. Files dropped on the window go to ioPix through
/// the same queue as the menu bar. The library itself is browsed in ioPix Native, the iPhone and iPad app on the Mac.
struct MainWindow: View {
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var watcher: PhotosWatcher
    @Environment(\.openWindow) private var openWindow
    @State private var dropping = false

    var body: some View {
        MenuView()
            .frame(minWidth: 380, minHeight: 360)
            .overlay { if dropping { DropHint() } }
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in queue.add(files: MenuView.expand(url)) }
                    }
                }
                return true
            }
            .navigationTitle("ioPix")
            .task { await queue.refreshAccount() }
            .onAppear { Router.openWindow = openWindow }
    }
}

enum MacFiles {
    /// The open panel for photos, videos and folders of them.
    static func choose() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .movie, .folder]
        panel.message = "Choose photos and videos to send to ioPix"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.flatMap(MenuView.expand)
    }
}
