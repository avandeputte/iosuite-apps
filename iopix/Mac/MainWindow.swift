import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The iopix window: the library itself (the web app), with the uploads in the toolbar. Files dropped on the
/// window go to iopix through the same queue as the menu bar.
struct MainWindow: View {
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var watcher: PhotosWatcher
    @Environment(\.openWindow) private var openWindow
    @State private var server = AppConfig.serverURL
    @State private var showUploads = false
    @State private var dropping = false

    var body: some View {
        IopixWebView(url: server) { Task { await queue.refreshAccount() } }
            .id(server)
            .frame(minWidth: 720, minHeight: 480)
            .overlay {
                if dropping {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .background(Color.accentColor.opacity(0.08))
                        .overlay(Text("Drop to send to iopix").font(.title2.weight(.semibold)))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in queue.add(files: MenuView.expand(url)) }
                    }
                }
                return true
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { queue.add(files: MacFiles.choose()) } label: {
                        Label("Send Files", systemImage: "square.and.arrow.up")
                    }
                    .help("Choose photos and videos to send to iopix")
                    .disabled(!queue.canSend && queue.account != nil)

                    if !queue.reviewing.isEmpty {
                        Button { openWindow(id: "review") } label: {
                            Label("\(queue.reviewing.count) New", systemImage: "photo.badge.plus")
                                .labelStyle(.titleAndIcon)
                        }
                        .help("New photos in your Photos library, waiting for you to pick")
                    }

                    Button { showUploads.toggle() } label: {
                        Label(queue.pending.isEmpty ? "Uploads" : "\(queue.pending.count) Sending",
                              systemImage: queue.pending.isEmpty ? "tray.and.arrow.up" : "arrow.up.circle")
                    }
                    .help("What is being sent to iopix")
                    .popover(isPresented: $showUploads, arrowEdge: .bottom) {
                        MenuView().environmentObject(queue).environmentObject(watcher)
                    }

                    Button { server = AppConfig.serverURL; reload() } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .help("Reload the page")
                }
            }
            .navigationTitle("iopix")
            .task { await queue.refreshAccount() }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                if AppConfig.serverURL != server { server = AppConfig.serverURL }  // changed in Settings
            }
    }

    private func reload() {
        NotificationCenter.default.post(name: .iopixReload, object: nil)
    }
}

extension Notification.Name {
    static let iopixReload = Notification.Name("iopixReload")
}

enum MacFiles {
    /// The open panel for photos, videos and folders of them.
    static func choose() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .movie, .folder]
        panel.message = "Choose photos and videos to send to iopix"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.flatMap(MenuView.expand)
    }
}
