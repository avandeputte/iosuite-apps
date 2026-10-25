import Foundation

/// Who this device is signed in as on iopix.
struct Account: Equatable {
    var name: String?
    var signedIn: Bool
    var canWrite: Bool
    var isAdmin = false
    var person: Int? = nil  // the person in the library this account is ("Photos of me")
}

/// What became of one file sent to iopix.
enum UploadOutcome: Equatable {
    case added
    case alreadyThere
    case skipped(String)
}

enum IopixError: LocalizedError, Equatable {
    case needsSignIn
    case needsServerUpdate  // the chosen folder needs a newer iopix
    case notAllowed(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .needsSignIn: return "Sign in to iopix to send photos."
        case .needsServerUpdate: return "Your iopix server can't put photos in a folder of your choice yet. Update iopix, or pick one of its date layouts in Settings."
        case .notAllowed(let why): return why
        case .server(let why): return why
        }
    }
}

/// Talks to iopix the way its web app does: the sign-in cookies (iopix's own session and, from outside,
/// Cloudflare Access's), then the import endpoints, which put each file in the library's dated folders
/// and skip anything already there. The server does every write; the apps only send files.
final class IopixClient: NSObject, URLSessionTaskDelegate {
    static let shared = IopixClient()

    private(set) var session: URLSession!

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = AppConfig.cookies
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 6 * 3600  // a long video over a slow connection
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /// A redirect to another host (Cloudflare's sign-in page, a misconfigured proxy) is not followed, so the sign-in
    /// cookies and the service token never reach anyone but the server; `check` then reports a needed sign-in.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.host?.lowercased() == server.host?.lowercased() ? request : nil)
    }

    var server: URL { AppConfig.serverURL }

    func request(_ path: String, method: String = "GET") -> URLRequest {
        // a path may carry its own query ("face/12?v=3"): only the part before ? is a path
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var url = server.appendingPathComponent(parts[0])
        if parts.count == 2, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.percentEncodedQuery = parts[1]
            url = c.url ?? url
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let id = ServiceToken.clientID, let secret = ServiceToken.clientSecret {
            r.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
            r.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        return r
    }

    /// The JSON answer, or the reason there is none. Cloudflare's sign-in shows up as a redirect to another
    /// host or as an HTML page instead of JSON.
    func check(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else { throw IopixError.server("The server did not answer.") }
        if let host = http.url?.host?.lowercased(), host != server.host?.lowercased() {
            throw IopixError.needsSignIn
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = json?["detail"] as? String
        switch http.statusCode {
        case 300..<400:  // a redirect that was not followed: another host wants a sign-in first
            throw IopixError.needsSignIn
        case 200..<300:
            if let json { return json }
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            throw type.contains("html") ? IopixError.needsSignIn : IopixError.server("The server sent an answer the app does not understand.")
        case 401:
            throw IopixError.needsSignIn
        case 403:
            throw json == nil ? IopixError.needsSignIn : IopixError.notAllowed(detail ?? "This account cannot add photos.")
        case 502, 503, 504:  // iopix is restarting or out of reach behind Cloudflare: worth trying again later
            throw URLError(.cannotConnectToHost)
        default:
            throw IopixError.server(detail ?? "The server answered with error \(http.statusCode).")
        }
    }

    /// Is there an iopix at this address? nil when there is (or a sign-in page in front of it, such as
    /// Cloudflare Access's), otherwise what went wrong, in plain words.
    func probe(_ url: URL) async -> String? {
        var r = URLRequest(url: url.appendingPathComponent("api/status"), timeoutInterval: 15)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return "No answer from that address." }
            if http.url?.host?.lowercased() != url.host?.lowercased() { return nil }  // sent to a sign-in page first
            if let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], j["appVersion"] != nil { return nil }
            if http.statusCode == 401 || http.statusCode == 403 { return nil }
            return "That address answers, but it isn't an iopix server."
        } catch let e as URLError where e.code == .cannotFindHost || e.code == .dnsLookupFailed {
            return "No server by that name. Check the address."
        } catch {
            return "Couldn't reach that address: \(error.localizedDescription)"
        }
    }

    func account() async throws -> Account {
        let (data, resp) = try await session.data(for: request("api/auth/me"))
        let j = try check(data, resp)
        let user = j["user"] as? [String: Any]
        return Account(name: user?["name"] as? String,
                       signedIn: j["signedIn"] as? Bool ?? false,
                       canWrite: j["canWrite"] as? Bool ?? false,
                       isAdmin: j["isAdmin"] as? Bool ?? false,
                       person: (user?["person"] as? NSNumber)?.intValue)
    }

    /// The accounts on the sign-in screen: name, and whether it needs a password.
    func accounts() async throws -> [(name: String, needsPassword: Bool)] {
        let (data, resp) = try await session.data(for: request("api/auth/accounts"))
        let j = try check(data, resp)
        return (j["accounts"] as? [[String: Any]] ?? []).compactMap { a in
            guard let n = a["name"] as? String else { return nil }
            return (n, !(a["passwordless"] as? Bool ?? false))
        }
    }

    /// Signs in with a name and password (the Apple TV has no web page to sign in on).
    func signIn(name: String, password: String) async throws {
        var r = request("api/auth/login", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "password": password])
        let (data, resp) = try await session.data(for: r)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 429 || http.statusCode == 403 {
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["detail"] as? String
            throw IopixError.notAllowed(detail ?? "Wrong user name or password")
        }
        _ = try check(data, resp)
    }

    /// Any JSON endpoint, as a dictionary.
    func json(_ path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        var r = request(path)
        if !query.isEmpty, var c = URLComponents(url: r.url!, resolvingAgainstBaseURL: false) {
            c.queryItems = query
            r.url = c.url
        }
        let (data, resp) = try await session.data(for: r)
        return try check(data, resp)
    }

    func signOut() async {
        _ = try? await session.data(for: request("api/auth/logout", method: "POST"))
        forgetCookies()
    }

    func forgetCookies() {
        let host = server.host?.lowercased() ?? ""
        for c in AppConfig.cookies.cookies ?? [] where Self.cookie(c, matches: host) {
            AppConfig.cookies.deleteCookie(c)
        }
    }

    /// The folder layouts the server offers, and whether it takes folder patterns of your own.
    func layouts() async throws -> (layouts: [ServerLayout], patterns: Bool) {
        let (data, resp) = try await session.data(for: request("api/import/layouts"))
        let j = try check(data, resp)
        let list = (j["layouts"] as? [[String: Any]] ?? []).compactMap { l -> ServerLayout? in
            guard let key = l["key"] as? String else { return nil }
            return ServerLayout(key: key, pattern: l["pattern"] as? String ?? "", example: l["example"] as? String ?? key)
        }
        let patterns = j["patterns"] as? Bool ?? false
        patternSupport = patterns
        return (list, patterns)
    }

    /// Whether this server takes folder patterns, learnt once per server address (nil: not asked yet).
    private(set) var patternSupport: Bool? {
        get { patternServer == server ? patternKnown : nil }
        set { patternServer = server; patternKnown = newValue }
    }
    private var patternServer: URL?
    private var patternKnown: Bool?

    /// A cookie for this server: its domain is the host or a parent of it (never a mere suffix such as "example.net"
    /// matching "notexample.net").
    static func cookie(_ c: HTTPCookie, matches host: String) -> Bool {
        let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == d || host.hasSuffix("." + d)
    }

    /// Sends one file: staged first (iopix looks at it and checks for duplicates), then imported.
    func upload(file: URL, name: String, to destination: Destination = .current, progress: @escaping (Double) -> Void) async throws -> UploadOutcome {
        if destination.needsPatterns {
            if patternSupport != true { _ = try await layouts() }
            // an older server would ignore the pattern and use its own layout: better not to send than to misfile
            guard patternSupport == true else { throw IopixError.needsServerUpdate }
        }
        let boundary = "iopix-\(UUID().uuidString)"
        let body = try Multipart.write(file: file, name: name, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: body) }

        var stage = request("api/import/stage", method: "POST")
        stage.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.upload(for: stage, fromFile: body, delegate: ProgressDelegate(progress))
        let plan = try check(data, resp)
        guard let token = plan["token"] as? String else { throw IopixError.server("The server did not accept the file.") }

        let items = plan["items"] as? [[String: Any]] ?? []
        if let err = items.first?["error"] as? String {
            await discard(token)
            return .skipped(err)
        }
        if (plan["new"] as? Int ?? 0) == 0 {
            await discard(token)
            return .alreadyThere
        }

        var run = request("api/import/\(token)/run", method: "POST")
        run.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var fields: [String: Any] = ["duplicates": "skip"]
        fields.merge(destination.runFields) { _, new in new }
        run.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let (data2, resp2) = try await session.data(for: run)
        let result = try check(data2, resp2)
        if let added = result["added"] as? [Any], !added.isEmpty { return .added }
        if let s = (result["skipped"] as? [[String: Any]])?.first {
            if s["duplicate_of"] != nil && !(s["duplicate_of"] is NSNull) { return .alreadyThere }
            return .skipped(s["reason"] as? String ?? "iopix did not add it.")
        }
        return .skipped("iopix did not add it.")
    }

    private func discard(_ token: String) async {
        _ = try? await session.data(for: request("api/import/\(token)/discard", method: "POST"))
    }
}

private final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
    let report: (Double) -> Void
    init(_ report: @escaping (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

/// A multipart body written to a file, so a large video is streamed from disk and never held in memory.
enum Multipart {
    static func write(file: URL, name: String, boundary: String) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        // the body is a copy of the file: make sure the disk has room for it first (a full disk is a plain error,
        // not a crash)
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           let free = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           size + 50_000_000 > free {
            throw IopixError.notAllowed("Not enough free space on this device to send \(name).")
        }
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let sink = try FileHandle(forWritingTo: out)
        defer { try? sink.close() }
        do {
            let safe = name.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            try sink.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(safe)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            let source = try FileHandle(forReadingFrom: file)
            defer { try? source.close() }
            while let chunk = try source.read(upToCount: 4 << 20), !chunk.isEmpty {
                try sink.write(contentsOf: chunk)
            }
            try sink.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw IopixError.notAllowed("Could not prepare \(name) for sending: \(error.localizedDescription)")
        }
        return out
    }
}
