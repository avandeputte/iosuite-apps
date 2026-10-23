import SwiftUI
import AppKit
import Combine
import UserNotifications

/// Opens the iopix window (at a page of the web app) or one of the app's other windows from anywhere: a
/// notification, a link, Spotlight, Shortcuts. The window opener is picked up from the menu bar icon, which is
/// always there.
@MainActor
enum Router {
    static var openWindow: OpenWindowAction?
    static var pendingRoute: String?

    /// `route` is a page of the web app, such as "#/photos?md=10-23".
    static func show(_ route: String? = nil) {
        pendingRoute = route
        openWindow?(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .iopixNavigate, object: nil)
    }

    static func open(_ window: String) {
        openWindow?(id: window)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func todayRoute() -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        return String(format: "#/photos?md=%02d-%02d", c.month ?? 1, c.day ?? 1)
    }
}

extension Notification.Name {
    static let iopixNavigate = Notification.Name("iopixNavigate")
}

/// The Mac app's own settings for the extras.
@MainActor
final class MacPrefs: ObservableObject {
    static let shared = MacPrefs()
    private let d = UserDefaults.standard

    enum Source: String, CaseIterable, Identifiable {
        case off, onThisDay, favorites, random, person
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .onThisDay: return "On this day"
            case .favorites: return "Favorites"
            case .random: return "Rediscover (random)"
            case .person: return "A person"
            }
        }
    }

    @Published var notifyReview: Bool { didSet { d.set(notifyReview, forKey: "mac.notifyReview") } }
    @Published var notifyUploads: Bool { didSet { d.set(notifyUploads, forKey: "mac.notifyUploads") } }
    @Published var notifyOnThisDay: Bool { didSet { d.set(notifyOnThisDay, forKey: "mac.notifyOnThisDay") } }
    @Published var wallpaper: Source { didSet { d.set(wallpaper.rawValue, forKey: "mac.wallpaper") } }
    @Published var wallpaperPerson: Int { didSet { d.set(wallpaperPerson, forKey: "mac.wallpaperPerson") } }
    @Published var wallpaperHours: Int { didSet { d.set(wallpaperHours, forKey: "mac.wallpaperHours") } }
    @Published var screenSaver: Source { didSet { d.set(screenSaver.rawValue, forKey: "mac.screenSaver") } }
    @Published var screenSaverPerson: Int { didSet { d.set(screenSaverPerson, forKey: "mac.screenSaverPerson") } }

    init() {
        notifyReview = d.object(forKey: "mac.notifyReview") as? Bool ?? true
        notifyUploads = d.object(forKey: "mac.notifyUploads") as? Bool ?? true
        notifyOnThisDay = d.object(forKey: "mac.notifyOnThisDay") as? Bool ?? false
        wallpaper = Source(rawValue: d.string(forKey: "mac.wallpaper") ?? "") ?? .off
        wallpaperPerson = d.integer(forKey: "mac.wallpaperPerson")
        wallpaperHours = d.object(forKey: "mac.wallpaperHours") as? Int ?? 1
        screenSaver = Source(rawValue: d.string(forKey: "mac.screenSaver") ?? "") ?? .off
        screenSaverPerson = d.integer(forKey: "mac.screenSaverPerson")
    }
}

/// Photo ids from iopix for a source (On this day, favorites, random, a person).
enum PhotoSource {
    static func ids(_ source: MacPrefs.Source, person: Int = 0, max: Int = 60) async -> [Int] {
        let client = IopixClient.shared
        var q: [URLQueryItem] = [URLQueryItem(name: "type", value: "photo")]
        switch source {
        case .off: return []
        case .random:
            let j = try? await client.json("api/random", query: [URLQueryItem(name: "n", value: String(min(max, 60)))])
            return (j?["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        case .onThisDay:
            let c = Calendar.current.dateComponents([.month, .day], from: Date())
            q.append(URLQueryItem(name: "md", value: String(format: "%02d-%02d", c.month ?? 1, c.day ?? 1)))
        case .favorites:
            q.append(URLQueryItem(name: "fav", value: "1"))
        case .person:
            guard person > 0 else { return [] }
            q.append(URLQueryItem(name: "tag", value: String(person)))
        }
        let j = try? await client.json("api/photos", query: q)
        let all = (j?["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        if all.isEmpty && source == .onThisDay { return await ids(.random, max: max) }  // nothing on this date: random ones
        return Array(all.shuffled().prefix(max))
    }

    /// Downloads a photo (the screen-size preview, or the original) to `folder`; returns the file.
    static func download(_ id: Int, to folder: URL, original: Bool = false) async -> URL? {
        let client = IopixClient.shared
        var req = client.request(original ? "orig/\(id)" : "preview/\(id)")
        if original, let u = req.url, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            c.queryItems = [URLQueryItem(name: "dl", value: "1")]  // the original's own file name comes with it
            req.url = c.url
        }
        guard let (data, resp) = try? await client.session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        var name = "\(id).jpg"
        if original, let cd = http.value(forHTTPHeaderField: "Content-Disposition"),
           let r = cd.range(of: "filename=\"") {
            name = String(cd[r.upperBound...].prefix { $0 != "\"" })
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }
}

// MARK: - Dock

/// The Dock icon shows how many photos are waiting, and a progress bar while they go.
@MainActor
final class DockBadge {
    static let shared = DockBadge()
    private var bag: Set<AnyCancellable> = []
    private let bar = NSProgressIndicator()
    private var runTotal = 0

    func start() {
        let tile = NSApp.dockTile
        let view = NSView(frame: NSRect(origin: .zero, size: tile.size))
        let icon = NSImageView(frame: view.bounds)
        icon.image = NSApp.applicationIconImage
        icon.autoresizingMask = [.width, .height]
        view.addSubview(icon)
        bar.frame = NSRect(x: 14, y: 10, width: tile.size.width - 28, height: 16)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.isHidden = true
        view.addSubview(bar)
        tile.contentView = view
        UploadQueue.shared.$items
            .throttle(for: .milliseconds(300), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.update() }
            .store(in: &bag)
    }

    private func update() {
        let q = UploadQueue.shared
        let waiting = q.pending.count
        let review = q.reviewing.count
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : review > 0 ? "\(review) new" : nil
        if let current = q.current {
            runTotal = max(runTotal, waiting)
            let done = Double(runTotal - waiting) + current.progress
            bar.doubleValue = runTotal > 0 ? done / Double(runTotal) : current.progress
            bar.isHidden = false
        } else {
            runTotal = 0
            bar.isHidden = true
        }
        NSApp.dockTile.display()
    }
}

// MARK: - Notifications

/// "5 new photos to review", "Sent 12 photos to iopix", and, if wanted, a daily On this day.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var bag: Set<AnyCancellable> = []
    private var lastReview = 0
    private var reviewTimer: Task<Void, Never>?

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        lastReview = UploadQueue.shared.reviewing.count
        UploadQueue.shared.$items.sink { [weak self] _ in self?.reviewChanged() }.store(in: &bag)
        NotificationCenter.default.publisher(for: .iopixUploadsDone).sink { note in
            guard MacPrefs.shared.notifyUploads, let n = note.userInfo?["count"] as? Int, n > 0 else { return }
            Self.post("uploads", title: "Sent to iopix", body: n == 1 ? "1 photo was added to iopix." : "\(n) photos were added to iopix.", open: "main")
        }.store(in: &bag)
        Task {
            while !Task.isCancelled {
                await onThisDay()
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
            }
        }
    }

    /// New photos waiting for review: one notification for a burst of them.
    private func reviewChanged() {
        let now = UploadQueue.shared.reviewing.count
        defer { lastReview = now }
        guard now > lastReview, MacPrefs.shared.notifyReview else { return }
        reviewTimer?.cancel()
        reviewTimer = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            let n = UploadQueue.shared.reviewing.count
            guard n > 0 else { return }
            Self.post("review", title: "New photos for iopix", body: n == 1 ? "1 new photo to look at." : "\(n) new photos to look at.", open: "review")
        }
    }

    /// Once a day, after 9 in the morning, when something was taken on this date in earlier years.
    private func onThisDay() async {
        guard MacPrefs.shared.notifyOnThisDay else { return }
        let today = Date().formatted(.iso8601.year().month().day())
        guard UserDefaults.standard.string(forKey: "mac.otdNotified") != today,
              Calendar.current.component(.hour, from: Date()) >= 9 else { return }
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        guard let j = try? await IopixClient.shared.json("api/photos", query: [URLQueryItem(name: "md", value: String(format: "%02d-%02d", c.month ?? 1, c.day ?? 1))]),
              let n = (j["count"] as? NSNumber)?.intValue, n > 0 else { return }
        UserDefaults.standard.set(today, forKey: "mac.otdNotified")
        Self.post("otd", title: "On this day", body: n == 1 ? "1 photo from this date in earlier years." : "\(n) photos from this date in earlier years.", open: "otd")
    }

    static func post(_ id: String, title: String, body: String, open: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.userInfo = ["open": open]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let open = response.notification.request.content.userInfo["open"] as? String
        await MainActor.run {
            switch open {
            case "review": Router.open("review")
            case "otd": Router.show(Router.todayRoute())
            case "card": Router.open("card")
            default: Router.show()
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
