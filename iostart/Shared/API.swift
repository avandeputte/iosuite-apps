import Foundation

enum APIError: LocalizedError {
    case signedOut
    case readOnly
    case server(Int, String)
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "The start page no longer accepts this phone's sign-in. Sign in again."
        case .readOnly: return "This account can read the bookmarks, not change them."
        case .server(let code, let msg): return msg.isEmpty ? "The start page answered with an error (\(code))." : msg
        case .unreachable(let msg): return msg
        }
    }
}

/// The start page's API for bookmarks, the day, tasks and events (`/dav/ext`, app/bookmarkext.py), called with the
/// app password the sign-in made for this phone (shared/DeviceSignIn) as a Bearer token.
struct API {
    var account: Account

    /// The widgets set a shorter one: a widget has seconds, not a minute, to get its timeline.
    static var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25
        c.waitsForConnectivity = true        // a phone just unlocked, or an app just installed: wait for the network
        c.timeoutIntervalForResource = 40    // instead of failing at once with "appears to be offline"; this long at most
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    /// An error answer: {"error": "…"}, {"detail": "…"}, or {"detail": {"error": "…", "signInAgain": true}}.
    private struct Failure: Decodable {
        struct Detail: Decodable { var error: String?; var signInAgain: Bool? }
        var error: String?
        var detail: String?
        var details: Detail?
        enum CodingKeys: String, CodingKey { case error, detail }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            error = try? c.decode(String.self, forKey: .error)
            detail = try? c.decode(String.self, forKey: .detail)
            details = try? c.decode(Detail.self, forKey: .detail)
        }
    }

    static func bearer(_ account: Account) -> String { "Bearer " + account.password }

    /// The errors of a network that was not there for a moment: worth one more try before telling anyone. A newly
    /// installed app's first request often fails as "offline" while iOS is still setting up its network access.
    private static let passing: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .secureConnectionFailed,
    ]

    private static func run(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var tries = 0
        while true {
            tries += 1
            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw APIError.unreachable("The start page did not answer.") }
                return (data, http)
            } catch let e as APIError {
                throw e
            } catch let e as URLError where passing.contains(e.code) && tries < 2 {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            } catch {
                let host = req.url?.host ?? "the start page"
                throw APIError.unreachable("Could not reach \(host): \(error.localizedDescription)")
            }
        }
    }

    private static func message(_ data: Data) -> String {
        let f = try? JSONDecoder().decode(Failure.self, from: data)
        return f?.error ?? f?.detail ?? f?.details?.error ?? ""
    }

    private func call<T: Decodable>(_ method: String, _ path: String, body: Data? = nil) async throws -> T {
        guard let url = URL(string: account.server + path) else { throw APIError.unreachable("The start page's address is not usable.") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(API.bearer(account), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, http) = try await API.run(req)
        switch http.statusCode {
        case 200..<300:
            do { return try JSONDecoder().decode(T.self, from: data) } catch {
                throw APIError.unreachable("The start page's answer could not be read. Is it up to date?")
            }
        case 401: throw APIError.signedOut
        case 403:
            throw APIError.readOnly
        default: throw APIError.server(http.statusCode, API.message(data))
        }
    }

    func hello() async throws -> Hello { try await call("GET", "/dav/ext") }
    func tree() async throws -> TreeState { try await call("GET", "/dav/ext/tree") }

    // MARK: widgets and Siri

    /// Today's events (or the next one), the week's, and the tasks due today or late (`tz`: this phone's zone).
    func today() async throws -> TodayData {
        let tz = TimeZone.current.identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return try await call("GET", "/dav/ext/today?tz=" + tz)
    }

    /// The calendars and the task lists that can be added to.
    func calendars() async throws -> Calendars { try await call("GET", "/dav/ext/calendars") }

    struct NewTask: Encodable { var title: String; var due: String?; var listId: SuiteID?; var timezone: String? }
    struct NewEvent: Encodable {
        var title: String; var start: String; var end: String?; var allDay: Bool; var timezone: String?; var calendarId: SuiteID?
    }

    func addTask(_ t: NewTask) async throws -> Added { try await call("POST", "/dav/ext/tasks", body: try JSONEncoder().encode(t)) }
    func addEvent(_ e: NewEvent) async throws -> Added { try await call("POST", "/dav/ext/events", body: try JSONEncoder().encode(e)) }

    private struct Changes: Encodable { var base: Int; var ops: [Op] }

    func sync(base: Int, ops: [Op]) async throws -> SyncResult {
        try await call("POST", "/dav/ext/sync", body: try JSONEncoder().encode(Changes(base: base, ops: ops)))
    }

    /// Where the icon of a link's site is served from (GET with the Bearer header).
    func iconURL(for id: Int) -> URL? {
        URL(string: account.server + "/dav/ext/icon/\(id)")
    }
}
