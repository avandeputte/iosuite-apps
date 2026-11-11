import AppKit

/// Answers the "Save to ionote" items in the right-click menu (Services) of other apps.
/// The menu items are declared under NSServices in Info.plist (see project.yml).
@MainActor
final class ServiceProvider: NSObject {
    private let store: NotesStore

    init(store: NotesStore) {
        self.store = store
    }

    /// Selected text, from any app: right-click › Save to ionote.
    @objc func saveToNotes(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        if let text = pboard.string(forType: .string), store.createTextNote(text, source: "service", sourceApp: app) != nil {
            confirm()
            return
        }
        if let type = pboard.availableType(from: [.png, .tiff]), let data = pboard.data(forType: type) {
            store.createImageNote(data: data, source: "service", sourceApp: app)
            confirm()
            return
        }
        error.pointee = "There was no text to save." as NSString
    }

    /// Image files selected in Finder: right-click › Services › Save Image to ionote.
    @objc func saveFilesToNotes(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        var saved = 0
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let title = url.deletingPathExtension().lastPathComponent
            if store.createImageNote(data: data, title: title, source: "service", sourceApp: "Finder") != nil {
                saved += 1
            }
        }
        if saved > 0 { confirm() } else { error.pointee = "No images to save." as NSString }
    }

    private func confirm() {
        NSSound(named: "Pop")?.play()
    }
}
