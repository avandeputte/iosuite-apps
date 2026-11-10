import Foundation
import os

/// Who this device is signed in as.
struct Account: Equatable {
    var name: String?
    var role: String?
    var signedIn: Bool
    var canWrite: Bool
}

enum IonotesError: LocalizedError, Equatable {
    case noServer
    case needsSignIn
    case notAllowed(String)
    case tooLarge
    case server(String)

    var errorDescription: String? {
        switch self {
        case .noServer: return "Enter your ionotes server in Settings."
        case .needsSignIn: return "Sign in to your ionotes server in Settings."
        case .notAllowed(let why): return why
        case .tooLarge: return "That is more than the server takes in one request."
        case .server(let why): return why
        }
    }
}

/// Talks to the ionotes server: the sign-in cookie (and, from outside, Cloudflare Access's service token),
/// then the sync API. Every time is seconds since 1970; ids are chosen by the device.
final class IonotesClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = IonotesClient()
    static let log = Logger(subsystem: "net.iothing.ionotes", category: "network")

    private(set) var session: URLSession!
    /// Read from the Keychain once and kept, so every request doesn't ask the Keychain again.
    private var token: (id: String, secret: String)?

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = .shared  // persisted, so the 30-day session survives a restart
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        reloadToken()
    }

    func reloadToken() {
        if let id = ServiceToken.clientID, let secret = ServiceToken.clientSecret { token = (id, secret) } else { token = nil }
    }

    /// A redirect to another host (Cloudflare's sign-in page, a misconfigured proxy) is not followed, so the
    /// session cookie and the service token never reach anyone but the server.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let same = request.url?.host?.lowercased() == task.originalRequest?.url?.host?.lowercased()
        completionHandler(same ? request : nil)
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], server: URL? = nil) throws -> URLRequest {
        guard let base = server ?? ServerConfig.serverURL else { throw IonotesError.noServer }
        var url = base.appendingPathComponent(path)
        if !query.isEmpty, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.queryItems = query
            url = c.url ?? url
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            r.setValue(token.id, forHTTPHeaderField: "CF-Access-Client-Id")
            r.setValue(token.secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        return r
    }

    private func jsonRequest(_ path: String, method: String, body: Any) throws -> URLRequest {
        var r = try request(path, method: method)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    /// The JSON answer, or why there is none. Cloudflare's sign-in shows up as a redirect to another host
    /// or as an HTML page instead of JSON.
    private func check(_ data: Data, _ response: URLResponse, allow: Set<Int> = []) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else { throw IonotesError.server("The server did not answer.") }
        if let host = http.url?.host?.lowercased(), host != ServerConfig.serverURL?.host?.lowercased() {
            throw IonotesError.needsSignIn
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = json?["detail"] as? String
        if allow.contains(http.statusCode), let json { return json }
        switch http.statusCode {
        case 200..<300:
            if let json { return json }
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            throw type.contains("html") ? IonotesError.needsSignIn : IonotesError.server("The server sent an answer ionotes does not understand.")
        case 300..<400, 401:
            throw IonotesError.needsSignIn
        case 403:
            throw json == nil ? IonotesError.needsSignIn : IonotesError.notAllowed(detail ?? "This account can only read notes.")
        case 413:
            throw IonotesError.tooLarge
        case 502, 503, 504:
            throw URLError(.cannotConnectToHost)
        default:
            let text = String(data: data.prefix(500), encoding: .utf8) ?? ""
            Self.log.error("\(http.url?.path ?? "", privacy: .public) answered \(http.statusCode): \(text, privacy: .public)")
            throw IonotesError.server(detail ?? "The server answered with error \(http.statusCode).")
        }
    }

    private func send(_ r: URLRequest, allow: Set<Int> = []) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: r)
        return try check(data, resp, allow: allow)
    }

    // MARK: - Status and sign-in

    /// Is there an ionotes server at this address? nil when there is, otherwise what went wrong, in plain words.
    func probe(_ url: URL) async -> String? {
        do {
            var r = try request("api/status", server: url)
            r.timeoutInterval = 10
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return "No answer from that address." }
            if http.url?.host?.lowercased() != url.host?.lowercased() || (300..<400).contains(http.statusCode) {
                return nil  // a sign-in page in front of it (Cloudflare Access)
            }
            if let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], j["app"] as? String == "ionotes" { return nil }
            if http.statusCode == 401 || http.statusCode == 403 { return nil }
            return "That address answers, but it isn't an ionotes server."
        } catch let e as URLError where e.code == .cannotFindHost || e.code == .dnsLookupFailed {
            return "No server by that name. Check the address."
        } catch {
            return "Couldn't reach that address: \(error.localizedDescription)"
        }
    }

    func account() async throws -> Account {
        let j = try await send(try request("api/auth/me"))
        let user = j["user"] as? [String: Any]
        return Account(name: user?["name"] as? String, role: user?["role"] as? String,
                       signedIn: j["signedIn"] as? Bool ?? false, canWrite: j["canWrite"] as? Bool ?? false)
    }

    func signIn(name: String, password: String) async throws {
        let r = try jsonRequest("api/auth/login", method: "POST", body: ["name": name, "password": password])
        let (data, resp) = try await session.data(for: r)
        if let code = (resp as? HTTPURLResponse)?.statusCode, [401, 403, 429].contains(code) {
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["detail"] as? String
            throw IonotesError.notAllowed(detail ?? "Wrong user name or password")
        }
        _ = try check(data, resp)
    }

    func signOut() async {
        if let r = try? request("api/auth/logout", method: "POST") { _ = try? await session.data(for: r) }
        forgetCookies()
    }

    func forgetCookies(for server: URL? = ServerConfig.serverURL) {
        guard let host = server?.host?.lowercased() else { return }
        for c in HTTPCookieStorage.shared.cookies ?? [] {
            let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if host == d || host.hasSuffix("." + d) { HTTPCookieStorage.shared.deleteCookie(c) }
        }
    }

    // MARK: - Sync

    /// Everything changed after `since`; ask again with the answer's rev while `more` is true.
    func changes(since: Int64, limit: Int = 500) async throws -> [String: Any] {
        try await send(try request("api/sync", query: [URLQueryItem(name: "since", value: String(since)),
                                                       URLQueryItem(name: "limit", value: String(limit))]))
    }

    /// Queued changes in one request; the answer has, per item, {status: ok|stale|error, item}.
    func push(notes: [[String: Any]], folders: [[String: Any]], tags: [[String: Any]]) async throws -> [String: Any] {
        var r = try jsonRequest("api/sync/push", method: "POST", body: ["notes": notes, "folders": folders, "tags": tags])
        r.timeoutInterval = 120
        return try await send(r)
    }

    /// Sends a note's picture (the note must already be on the server); answers the note, with its new imageSHA.
    func uploadImage(_ data: Data, noteID: String) async throws -> [String: Any] {
        var r = try request("api/notes/\(noteID)/image", method: "PUT")
        r.setValue(ImageCoding.mimeType(of: data), forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 300
        let (body, resp) = try await session.upload(for: r, from: data)
        if (resp as? HTTPURLResponse)?.statusCode == 400 {
            let detail = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["detail"] as? String
            throw IonotesError.notAllowed(detail ?? "The server could not read this picture.")
        }
        return try check(body, resp)
    }

    /// The note's picture as stored on the server, or nil when it has none (any more).
    func downloadImage(noteID: String) async throws -> Data? {
        var r = try request("api/notes/\(noteID)/image")
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 300
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw IonotesError.server("The server did not answer.") }
        if http.statusCode == 404 { return nil }
        let sameHost = http.url?.host?.lowercased() == ServerConfig.serverURL?.host?.lowercased()
        if sameHost, http.statusCode == 200, (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("image/") {
            return data
        }
        _ = try check(data, resp)  // throws the reason (a sign-in page, an error)
        throw IonotesError.server("The server sent no picture.")
    }
}
