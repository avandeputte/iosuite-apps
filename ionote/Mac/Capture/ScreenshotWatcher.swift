import Foundation

/// Watches the folder macOS saves screenshots to and hands each new screenshot to the store.
@MainActor
final class ScreenshotWatcher {
    private let store: NotesStore
    private var watcher: DirectoryWatcher?
    private var seen = Set<String>()
    private var startedAt = Date()
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]

    init(store: NotesStore) {
        self.store = store
    }

    /// Where screenshots go: the folder chosen in the Screenshot app's Options, or the Desktop.
    static var screenshotFolder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    var isRunning: Bool { watcher != nil }

    func start() {
        guard watcher == nil else { return }
        startedAt = Date()
        seen = Set(currentImages().map(\.path))
        // A screenshot is written under a hidden name first and renamed when done, and the floating
        // thumbnail can hold it back a few seconds, so wait a moment after each change.
        watcher = DirectoryWatcher(url: ScreenshotWatcher.screenshotFolder, delay: 1.0) { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    func stop() {
        watcher = nil
    }

    private func scan() {
        for url in currentImages() where !seen.contains(url.path) {
            seen.insert(url.path)
            guard ScreenshotWatcher.isScreenshot(url), created(url) >= startedAt.addingTimeInterval(-5) else { continue }
            store.addScreenshot(at: url)
        }
    }

    private func currentImages() -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: ScreenshotWatcher.screenshotFolder,
                                                                  includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return urls.filter { ScreenshotWatcher.imageExtensions.contains($0.pathExtension.lowercased()) }
    }

    private func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
    }

    /// macOS tags screenshots with the kMDItemIsScreenCapture attribute, whatever the file name or language.
    static func isScreenshot(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        if getxattr(url.path, name, nil, 0, 0, 0) > 0 { return true }
        let lower = url.lastPathComponent.lowercased()
        return lower.hasPrefix("screenshot") || lower.hasPrefix("screen shot")
    }
}
