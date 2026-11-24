import SwiftUI

/// The TV's own settings: how slideshows run and when ambient mode starts.
@MainActor
final class TVPrefs: ObservableObject {
    static let shared = TVPrefs()
    private let d = AppConfig.defaults

    enum AmbientSource: String, CaseIterable, Identifiable {
        case rediscover, favorites, onThisDay
        var id: String { rawValue }
        var label: String {
            switch self {
            case .rediscover: return "Rediscover (random)"
            case .favorites: return "Favorites"
            case .onThisDay: return "On this day"
            }
        }
    }

    @Published var slideSeconds: Int { didSet { d.set(slideSeconds, forKey: "tv.slideSeconds") } }
    @Published var shuffle: Bool { didSet { d.set(shuffle, forKey: "tv.shuffle") } }
    @Published var panAndZoom: Bool { didSet { d.set(panAndZoom, forKey: "tv.panAndZoom") } }
    @Published var playVideos: Bool { didSet { d.set(playVideos, forKey: "tv.playVideos") } }
    @Published var ambientMinutes: Int { didSet { d.set(ambientMinutes, forKey: "tv.ambientMinutes") } }
    @Published var ambientSource: AmbientSource { didSet { d.set(ambientSource.rawValue, forKey: "tv.ambientSource") } }
    @Published var askWhoIsWatching: Bool { didSet { d.set(askWhoIsWatching, forKey: "tv.askWho") } }

    init() {
        slideSeconds = d.object(forKey: "tv.slideSeconds") as? Int ?? 6
        shuffle = d.bool(forKey: "tv.shuffle")
        panAndZoom = d.object(forKey: "tv.panAndZoom") as? Bool ?? true
        playVideos = d.bool(forKey: "tv.playVideos")
        ambientMinutes = d.object(forKey: "tv.ambientMinutes") as? Int ?? 5
        ambientSource = AmbientSource(rawValue: d.string(forKey: "tv.ambientSource") ?? "") ?? .rediscover
        askWhoIsWatching = d.object(forKey: "tv.askWho") as? Bool ?? true
    }
}

/// Accounts this TV has signed in with, each with an app password of its own (kept in the Keychain), so switching
/// needs no password.
enum Profiles {
    private static let listKey = "tv.profiles"

    /// Kept per server: a name that signed in on another server is not offered here.
    private static var host: String { AppConfig.serverURL.host?.lowercased() ?? "" }
    private static var hostKey: String { listKey + "." + host }
    static var names: [String] { AppConfig.defaults.stringArray(forKey: hostKey) ?? [] }

    /// Keeps a sign-in under its name.
    static func save(_ c: DeviceCredential) {
        Keychain.set(c.password, for: "device.\(host).\(c.name)")
        var list = names.filter { $0 != c.name }
        list.insert(c.name, at: 0)
        AppConfig.defaults.set(list, forKey: hostKey)
    }

    /// Makes `name`'s app password this TV's sign-in. False when it has none (any more).
    static func use(_ name: String) -> Bool {
        let store = DeviceCredentialStore(app: AppConfig.deviceApp)
        guard let pw = Keychain.get("device.\(host).\(name)") else { return false }
        let c = DeviceCredential(address: store.lastAddress ?? AppConfig.serverURL.absoluteString, base: AppConfig.serverURL, name: name, password: pw)
        store.save(c)
        IopixClient.shared.signedIn(c)
        save(c)
        return true
    }

    static func forget(_ name: String) {
        Keychain.set(nil, for: "device.\(host).\(name)")
        AppConfig.defaults.set(names.filter { $0 != name }, forKey: hostKey)
    }
}

/// Starts ambient mode after the remote has been left alone for a while (focus moves reset the clock).
@MainActor
final class AmbientClock: ObservableObject {
    @Published var active = false
    private var last = Date()
    private var timer: Task<Void, Never>?
    static var viewerOpen = 0  // a photo or slideshow is already on screen

    private var observer: NSObjectProtocol?

    deinit {
        timer?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        observer = NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.touch() }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled, let self {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                let minutes = TVPrefs.shared.ambientMinutes
                if minutes > 0, !self.active, Self.viewerOpen == 0, Date().timeIntervalSince(self.last) > Double(minutes * 60) {
                    self.active = true
                }
            }
        }
    }

    func touch() { last = Date() }
}
