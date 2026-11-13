import SwiftUI
import UniformTypeIdentifiers

/// What a right-click on a picture offers: copy, save, open, and share (Messages, Mail, AirDrop…).
struct ImageMenu: View {
    /// A PNG of the picture with a readable name, made when the picture is shown.
    let fileURL: URL?
    let copy: () -> Void

    var body: some View {
        Button("Copy Image", action: copy)
        if let fileURL {
            Button("Save Image As…") { ImageFiles.saveAs(fileURL) }
            Button("Open in Preview") { NSWorkspace.shared.open(fileURL) }
            Divider()
            ShareLink(item: fileURL) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        }
    }
}

enum ImageFiles {
    /// Asks where to save the picture (as PNG) and copies it there.
    @MainActor
    static func saveAs(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
