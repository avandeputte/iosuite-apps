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

/// Accounts this TV has signed in with, each with its own iopix session, so switching needs no password.
/// The sessions are kept in the Keychain.
enum Profiles {
    private static let listKey = "tv.profiles"

    /// Kept per server: a name that signed in on another server is not offered as password-free here.
    private static var hostKey: String { listKey + "." + (AppConfig.serverURL.host?.lowercased() ?? "") }
    static var names: [String] { AppConfig.defaults.stringArray(forKey: hostKey) ?? [] }

    /// Keeps the current sign-in cookies under `name`.
    static func save(_ name: String) {
        let host = AppConfig.serverURL.host?.lowercased() ?? ""
        let cookies = (AppConfig.cookies.cookies ?? []).filter { CookieMatch.matches($0, host) }
        let plain: [[String: Any]] = cookies.map { c in
            var p: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path, "secure": c.isSecure]
            if let e = c.expiresDate { p["expires"] = e.timeIntervalSince1970 }
            return p
        }
        guard let data = try? JSONSerialization.data(withJSONObject: plain), let text = String(data: data, encoding: .utf8) else { return }
        Keychain.set(text, for: "profile.\(host).\(name)")
        var list = names.filter { $0 != name }
        list.insert(name, at: 0)
        AppConfig.defaults.set(list, forKey: hostKey)
    }

    /// Puts `name`'s session back in place. False when it has none (any more).
    static func use(_ name: String) -> Bool {
        let host = AppConfig.serverURL.host?.lowercased() ?? ""
        guard let text = Keychain.get("profile.\(host).\(name)"), let data = text.data(using: .utf8),
              let plain = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        IopixClient.shared.forgetCookies()
        for p in plain {
            var props: [HTTPCookiePropertyKey: Any] = [.name: p["name"] ?? "", .value: p["value"] ?? "", .domain: p["domain"] ?? host, .path: p["path"] ?? "/"]
            if let e = p["expires"] as? Double { props[.expires] = Date(timeIntervalSince1970: e) }
            if p["secure"] as? Bool == true { props[.secure] = "TRUE" }
            if let c = HTTPCookie(properties: props) { AppConfig.cookies.setCookie(c) }
        }
        var list = names.filter { $0 != name }
        list.insert(name, at: 0)
        AppConfig.defaults.set(list, forKey: hostKey)
        return true
    }

    static func forget(_ name: String) {
        let host = AppConfig.serverURL.host?.lowercased() ?? ""
        Keychain.set(nil, for: "profile.\(host).\(name)")
        AppConfig.defaults.set(names.filter { $0 != name }, forKey: hostKey)
    }
}

enum CookieMatch {
    static func matches(_ c: HTTPCookie, _ host: String) -> Bool {
        let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == d || host.hasSuffix("." + d)
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
