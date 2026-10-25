import SwiftUI
import AppIntents

/// Shortcuts actions (and Siri phrases): send files to iopix, show On this day, search, review new photos.

struct SendToIopix: AppIntent {
    static var title: LocalizedStringResource = "Send to iopix"
    static var description = IntentDescription("Sends photos and videos to your iopix library. iopix skips the ones it already has.")

    @Parameter(title: "Photos and videos")
    var files: [IntentFile]

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let files = self.files
        // files on disk are copied by name (a 3 GB video is never read into memory); only in-memory items are written out
        let urls: [URL] = try await Task.detached(priority: .userInitiated) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shortcut-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var urls: [URL] = []
            for (i, f) in files.enumerated() {
                let name = f.filename.isEmpty ? "photo-\(i).jpg" : f.filename
                let dst = dir.appendingPathComponent(name)
                if let src = f.fileURL { try FileManager.default.copyItem(at: src, to: dst) } else { try f.data.write(to: dst) }
                urls.append(dst)
            }
            return urls
        }.value
        await UploadQueue.shared.add(files: urls, move: true)
        return .result(dialog: urls.count == 1 ? "Sending 1 item to iopix." : "Sending \(urls.count) items to iopix.")
    }
}

struct ShowOnThisDay: AppIntent {
    static var title: LocalizedStringResource = "Show On this day in iopix"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        Router.shared.open(String(format: "#/photos?md=%02d-%02d", c.month ?? 1, c.day ?? 1))
        return .result()
    }
}

struct SearchIopix: AppIntent {
    static var title: LocalizedStringResource = "Search iopix"
    static var openAppWhenRun = true

    @Parameter(title: "Search for")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        var q = URLComponents()
        q.queryItems = [URLQueryItem(name: "q", value: text)]
        Router.shared.open("#/photos?\(q.percentEncodedQuery ?? "")")
        return .result()
    }
}

struct ReviewNewPhotos: AppIntent {
    static var title: LocalizedStringResource = "Review new photos for iopix"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .iopixSendPhotos, object: nil)
        return .result()
    }
}

struct IopixShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendToIopix(), phrases: ["Send to \(.applicationName)"], shortTitle: "Send to iopix", systemImageName: "square.and.arrow.up")
        AppShortcut(intent: ShowOnThisDay(), phrases: ["Show On this day in \(.applicationName)"], shortTitle: "On this day", systemImageName: "calendar")
        AppShortcut(intent: SearchIopix(), phrases: ["Search \(.applicationName)"], shortTitle: "Search iopix", systemImageName: "magnifyingglass")
        AppShortcut(intent: ReviewNewPhotos(), phrases: ["Review new photos in \(.applicationName)"], shortTitle: "Review new photos", systemImageName: "photo.badge.plus")
    }
}
