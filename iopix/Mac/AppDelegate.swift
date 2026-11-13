import SwiftUI
import AppKit
import AppIntents
import CoreSpotlight
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = Notifier.shared  // before launch ends: a clicked banner can start the app
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        Task { @MainActor in
            DockBadge.shared.start()
            Notifier.shared.start()
            FolderWatcher.shared.start()
            CardWatcher.shared.start()
            DesktopExtras.shared.start()
            Inbox.collect()
            // the Share menu extension wakes the app with iopix://inbox; this catches anything missed
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    Inbox.collect()
                }
            }
        }
    }

    /// iopix://inbox (Share menu), iopix://photo/<id> (widget), iopix://review.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls where url.scheme == "iopix" {
                switch url.host {
                case "inbox": Inbox.collect()
                case "review": Router.open("review")
                case "photo":
                    if let id = Int(url.lastPathComponent) { Router.show("#/photos?ids=\(id)&p=\(id)") }
                case "today": Router.show(Router.todayRoute())
                default: Router.show()
                }
            }
        }
    }

    /// A Spotlight result: its id is the page of the web app to open.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let route = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        Task { @MainActor in Router.show(route) }
        return true
    }

    /// Closing the window keeps iopix in the menu bar, still sending and watching.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - Shortcuts

struct SendToIopix: AppIntent {
    static var title: LocalizedStringResource = "Send to ioPix"
    static var description = IntentDescription("Sends photos and videos to your ioPix library. ioPix skips the ones it already has.")

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
        return .result(dialog: urls.count == 1 ? "Sending 1 item to ioPix." : "Sending \(urls.count) items to ioPix.")
    }
}

struct ShowOnThisDay: AppIntent {
    static var title: LocalizedStringResource = "Show On this day in ioPix"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Router.show(Router.todayRoute())
        return .result()
    }
}

struct SearchIopix: AppIntent {
    static var title: LocalizedStringResource = "Search ioPix"
    static var openAppWhenRun = true

    @Parameter(title: "Search for")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        var q = URLComponents()
        q.queryItems = [URLQueryItem(name: "q", value: text)]
        Router.show("#/photos?\(q.percentEncodedQuery ?? "")")
        return .result()
    }
}

struct ReviewNewPhotos: AppIntent {
    static var title: LocalizedStringResource = "Review new photos for ioPix"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Router.open("review")
        return .result()
    }
}

struct IopixShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendToIopix(), phrases: ["Send to \(.applicationName)"], shortTitle: "Send to ioPix", systemImageName: "square.and.arrow.up")
        AppShortcut(intent: ShowOnThisDay(), phrases: ["Show On this day in \(.applicationName)"], shortTitle: "On this day", systemImageName: "calendar")
        AppShortcut(intent: SearchIopix(), phrases: ["Search \(.applicationName)"], shortTitle: "Search ioPix", systemImageName: "magnifyingglass")
        AppShortcut(intent: ReviewNewPhotos(), phrases: ["Review new photos in \(.applicationName)"], shortTitle: "Review new photos", systemImageName: "photo.badge.plus")
    }
}
