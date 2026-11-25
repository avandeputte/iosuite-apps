import Foundation

/// The home address of ioPix (Settings › Home address), for what the address for apps does not serve: the admin and
/// maintenance screens. It is the pages' address on the home network (e.g.
/// http://192.168.1.10:8080/pix), which takes the same app password from inside the network. Away from home, or
/// without one, those screens say "Available at home only".
final class HomeServer: ObservableObject {
    static let shared = HomeServer()

    static let unavailable = "Available at home only. Add the home address in Settings, and use it on your home network."
    static let hint = "Home address (for admin screens), e.g. http://192.168.1.10:8080/pix"

    enum State: Equatable { case unknown, notSet, reachable, unreachable }

    @Published private(set) var state: State = AppConfig.homeURL == nil ? .notSet : .unknown
    private var checked = Date.distantPast
    private var checking: Task<Bool, Never>?
    private let lock = NSLock()

    /// Whether the home address answers now (asked again after a minute, or after `forget`).
    var isReachable: Bool { lock.lock(); defer { lock.unlock() }; return known == .reachable }

    /// Asks the home address whether it is ioPix and takes this device's app password (GET api/status).
    @discardableResult
    func check(force: Bool = false) async -> Bool {
        lock.lock()
        if !force, known != .unknown, Date().timeIntervalSince(checked) < 60 { let s = known; lock.unlock(); return s == .reachable }
        if let running = checking { lock.unlock(); return await running.value }
        let task = Task { await Self.ask() }
        checking = task
        lock.unlock()
        let ok = await task.value
        let new: State = AppConfig.homeURL == nil ? .notSet : ok ? .reachable : .unreachable
        lock.lock(); checking = nil; checked = Date(); known = new; lock.unlock()
        await MainActor.run { self.state = new }
        return ok
    }

    /// The network moved or the address changed: ask again next time.
    func forget() {
        let s: State = AppConfig.homeURL == nil ? .notSet : .unknown
        lock.lock(); checked = .distantPast; known = s; lock.unlock()
        DispatchQueue.main.async { self.state = s }
    }

    private var known: State = AppConfig.homeURL == nil ? .notSet : .unknown

    private static func ask() async -> Bool {
        guard let home = AppConfig.homeURL, let c = IopixClient.shared.credential else { return false }
        var r = URLRequest(url: home.appendingPathComponent("api/status"), timeoutInterval: 4)
        c.authorize(&r)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await DeviceSignIn.session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return (j["app"] as? String) == "iopix" && (j["signedIn"] as? Bool ?? true)
    }

    /// Saves a typed home address ("" clears it). The app's folder is added like for the sign-in address.
    static func setAddress(_ typed: String) {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            AppConfig.homeURL = nil
        } else if let url = DeviceSignIn.candidates(t, app: AppConfig.deviceApp).first {
            AppConfig.homeURL = url
        }
        shared.forget()
    }

    /// The calls of ioPix that the address for apps does not answer (only the pages' port does): admin and
    /// maintenance. The originals (orig/) are served at both since ioSuite 4.2.1. `path` is relative to the app's address ("api/folders/3/move").
    static func isHomeOnly(_ path: String, method: String) -> Bool {
        let p = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let m = method.uppercased()
        guard p.hasPrefix("api/") else { return false }
        let parts = p.split(separator: "/").map(String.init)
        let area = parts.count > 1 ? parts[1] : ""
        switch area {
        case "auth": return !["api/auth/me", "api/auth/settings", "api/auth/device"].contains(p)
        case "folders": return !(parts.count == 2 && m == "GET")        // listed to pick a destination; managed at home
        case "metadata": return !(parts.count == 3 && m == "GET")       // read anywhere; reread at home
        case "trash": return p == "api/trash/empty"
        case "rotation": return parts.count == 2                         // the review list; dismissing one is everyday
        case "tools": return !(parts.count == 2 && m == "GET")          // the counts anywhere; the actions at home
        case "photos": return p == "api/photos/rename-pattern"
        case "people": return p == "api/people/birth"
        default: return homeAreas.contains(area)
        }
    }

    private static let homeAreas: Set<String> = [
        "backup", "database", "db", "library", "roots", "scan", "settings",
        "analysis", "models", "filecheck", "consistency", "quality", "duplicates", "neardups", "edits", "placetags",
        "placesuggest", "gpx", "datehints", "datesuggest", "clothing", "jerseys", "badges", "geocode", "maps",
    ]
}
