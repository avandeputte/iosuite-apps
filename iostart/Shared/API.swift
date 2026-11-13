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

/// The start page's sync API for bookmarks (`/dav/ext`, app/bookmarkext.py), and the sign-in flow that makes the
/// app password it is called with (`/dav/nextcloud/index.php/login/v2`, app/ncbookmarks.py).
struct API {
    var account: Account

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    private struct Failure: Decodable { var error: String?; var detail: String? }

    static func basic(_ account: Account) -> String {
        "Basic " + Data("\(account.user):\(account.password)".utf8).base64EncodedString()
    }

    private static func run(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw APIError.unreachable("The start page did not answer.") }
            return (data, http)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.unreachable(error.localizedDescription)
        }
    }

    private static func message(_ data: Data) -> String {
        let f = try? JSONDecoder().decode(Failure.self, from: data)
        return f?.error ?? f?.detail ?? ""
    }

    private func call<T: Decodable>(_ method: String, _ path: String, body: Data? = nil) async throws -> T {
        guard let url = URL(string: account.server + path) else { throw APIError.unreachable("The start page's address is not usable.") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(API.basic(account), forHTTPHeaderField: "Authorization")
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
        case 403: throw APIError.readOnly
        default: throw APIError.server(http.statusCode, API.message(data))
        }
    }

    func hello() async throws -> Hello { try await call("GET", "/dav/ext") }
    func tree() async throws -> TreeState { try await call("GET", "/dav/ext/tree") }

    private struct Changes: Encodable { var base: Int; var ops: [Op] }

    func sync(base: Int, ops: [Op]) async throws -> SyncResult {
        try await call("POST", "/dav/ext/sync", body: try JSONEncoder().encode(Changes(base: base, ops: ops)))
    }

    /// Where the icon of a link's site is served from (GET with the Basic header).
    func iconURL(for id: Int) -> URL? {
        URL(string: account.server + "/dav/ext/icon/\(id)")
    }

    // MARK: the sign-in flow

    struct Flow: Decodable {
        struct Poll: Decodable { var token: String }
        var poll: Poll
        var login: String
        /// The page to open, at the address the person typed (the server may know itself under another one).
        func page(on server: String) -> URL? {
            guard let last = login.split(separator: "/").last else { return nil }
            return URL(string: server + API.flowBase + "/flow/" + last)
        }
    }

    struct Granted: Decodable {
        var loginName: String
        var appPassword: String
    }

    private static let flowBase = "/dav/nextcloud/index.php/login/v2"

    /// A typed address as the server's root: with a scheme, without a trailing slash.
    static func root(_ typed: String) -> String {
        var s = tidyAddress(typed)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func startFlow(server: String, client: String) async throws -> Flow {
        var c = URLComponents(string: server + flowBase)
        c?.queryItems = [URLQueryItem(name: "client", value: client)]
        guard let url = c?.url, url.host != nil else { throw APIError.unreachable("That address is not usable.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (data, http) = try await run(req)
        guard http.statusCode == 200, let flow = try? JSONDecoder().decode(Flow.self, from: data) else {
            throw APIError.unreachable("No ioSuite start page with bookmarks answers at that address (it needs version 0.47 or later).")
        }
        return flow
    }

    /// Nil until somebody said yes on the page; then, once, the name and the app password.
    static func pollFlow(server: String, token: String) async throws -> Granted? {
        guard let url = URL(string: server + flowBase + "/poll") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["token": token])
        let (data, http) = try await run(req)
        guard http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Granted.self, from: data)
    }
}
