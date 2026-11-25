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
    /// 401: the server no longer takes this device's app password (removed in Settings › Account).
    case unauthorized
    case notAllowed(String)
    case tooLarge
    case server(String)

    var errorDescription: String? {
        switch self {
        case .noServer: return "Enter your ioNote server in Settings."
        case .needsSignIn: return "Sign in to your ioNote server in Settings."
        case .unauthorized: return "The server no longer accepts this device's sign-in. Sign in again in Settings."
        case .notAllowed(let why): return why
        case .tooLarge: return "That is more than the server takes in one request."
        case .server(let why): return why
        }
    }
}

/// Talks to the ioNote server: this device's app password as a Bearer header, then the sync API. Every time is seconds since 1970; ids are chosen by the device.
final class IonotesClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = IonotesClient()
    static let log = Logger(subsystem: "net.iothing.ionotes", category: "network")

    private(set) var session: URLSession!
    /// The address, name and app password this device signed in with (DeviceSignIn), read from the Keychain once.
    private(set) var credential: DeviceCredential?

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = nil  // no cookies: the app password goes with every request
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        LegacyServiceToken.remove()
        reloadCredential()
    }

    func reloadCredential() {
        credential = ServerConfig.store.load()
    }

    /// A redirect to another host (Cloudflare's sign-in page, a misconfigured proxy) is not followed, so the
    /// app password never reaches anyone but the server.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let same = request.url?.host?.lowercased() == task.originalRequest?.url?.host?.lowercased()
        completionHandler(same ? request : nil)
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) throws -> URLRequest {
        guard let credential else { throw ServerConfig.serverURL == nil ? IonotesError.noServer : IonotesError.needsSignIn }
        let base = credential.base
        var url = base.appendingPathComponent(path)
        if !query.isEmpty, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.queryItems = query
            url = c.url ?? url
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        credential.authorize(&r)
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
        if let host = http.url?.host?.lowercased(), host != credential?.base.host?.lowercased() {
            throw IonotesError.needsSignIn
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = json?["detail"] as? String
        if allow.contains(http.statusCode), let json { return json }
        switch http.statusCode {
        case 200..<300:
            if let json { return json }
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            throw type.contains("html") ? IonotesError.needsSignIn : IonotesError.server("The server sent an answer ioNote does not understand.")
        case 401:
            throw IonotesError.unauthorized
        case 300..<400:
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

    // MARK: - Account

    func account() async throws -> Account {
        let j = try await send(try request("api/auth/me"))
        let user = j["user"] as? [String: Any]
        return Account(name: user?["name"] as? String, role: user?["role"] as? String,
                       signedIn: j["signedIn"] as? Bool ?? false, canWrite: j["canWrite"] as? Bool ?? false)
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
        let sameHost = http.url?.host?.lowercased() == credential?.base.host?.lowercased()
        if sameHost, http.statusCode == 200, (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("image/") {
            return data
        }
        _ = try check(data, resp)  // throws the reason (a sign-in page, an error)
        throw IonotesError.server("The server sent no picture.")
    }

    // MARK: - Attached files

    /// Sends a file to attach to a note (the note must be on the server) under the id this device chose; `text`: what
    /// this device read from it (a picture's text), sent along so the server needn't. Answers the note.
    func uploadAttachment(_ data: Data, id: String, noteID: String, name: String, mime: String, text: String?) async throws -> [String: Any] {
        var r = try request("api/notes/\(noteID)/attachments/\(id)", method: "PUT", query: [URLQueryItem(name: "name", value: name)])
        r.setValue(mime.isEmpty ? "application/octet-stream" : mime, forHTTPHeaderField: "Content-Type")
        if let text, let encoded = String(text.prefix(3000)).addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            r.setValue(encoded, forHTTPHeaderField: "X-Ionote-Text")
        }
        r.timeoutInterval = 300
        let (body, resp) = try await session.upload(for: r, from: data)
        if (resp as? HTTPURLResponse)?.statusCode == 400 {
            let detail = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["detail"] as? String
            throw IonotesError.notAllowed(detail ?? "The server did not take this file.")
        }
        return try check(body, resp)
    }

    /// An attached file's bytes, or nil when it is gone from the server.
    func downloadAttachment(id: String, noteID: String) async throws -> Data? {
        var r = try request("api/notes/\(noteID)/attachments/\(id)")
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 300
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw IonotesError.server("The server did not answer.") }
        if http.statusCode == 404 { return nil }
        let sameHost = http.url?.host?.lowercased() == credential?.base.host?.lowercased()
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if sameHost, http.statusCode == 200, http.value(forHTTPHeaderField: "Content-Disposition") != nil || !type.contains("html") {
            return data
        }
        _ = try check(data, resp)
        throw IonotesError.server("The server sent no file.")
    }

    /// Takes a file off a note; answers the note.
    func deleteAttachment(id: String, noteID: String) async throws -> [String: Any] {
        try await send(try request("api/notes/\(noteID)/attachments/\(id)", method: "DELETE"))
    }
}
