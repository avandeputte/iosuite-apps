import Foundation
import OSLog
import CryptoKit

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
    case homeOnly  // an admin or maintenance call, which only the home address answers
    case server(String)

    var errorDescription: String? {
        switch self {
        case .needsSignIn: return "Sign in to ioPix."
        case .homeOnly: return HomeServer.unavailable
        case .needsServerUpdate: return "Your ioPix server can't put photos in a folder of your choice yet. Update ioPix, or pick one of its date layouts in Settings."
        case .notAllowed(let why): return why
        case .server(let why): return why
        }
    }
}

/// Talks to ioPix at its address for apps: every request carries this device's app password
/// ("Authorization: Bearer", from the device sign-in in shared/DeviceSignIn), and no cookie is kept or sent.
/// The admin and maintenance calls go to the home address instead (HomeServer), with the same app password.
final class IopixClient: NSObject, URLSessionTaskDelegate {
    static let shared = IopixClient()

    private(set) var session: URLSession!

    /// This device's sign-in, read from the Keychain once and kept (every thumbnail asks for it).
    private let credentialLock = NSLock()
    private var cachedCredential: DeviceCredential??

    var credential: DeviceCredential? {
        credentialLock.lock(); defer { credentialLock.unlock() }
        if let c = cachedCredential { return c }
        let c = DeviceCredentialStore(app: AppConfig.deviceApp).load()
        cachedCredential = .some(c)
        return c
    }

    var isSignedIn: Bool { credential != nil }

    /// Signed in on the sign-in screen (the credential is saved already): talk to where it answered.
    func signedIn(_ c: DeviceCredential) {
        credentialLock.lock(); cachedCredential = .some(c); credentialLock.unlock()
        AppConfig.serverURL = c.base
        session.configuration.urlCache?.removeAllCachedResponses()
        HomeServer.shared.forget()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .iopixSignedIn, object: nil) }
    }

    /// Sign out: the app password goes back to the server and the Keychain forgets it (the address and name stay,
    /// for the sign-in screen).
    func signOut() async {
        if let c = credential { await DeviceSignIn.signOut(c) }
        forget()
    }

    /// The app password was refused (removed in Settings › Account): forgotten, and the sign-in screen comes back with
    /// the address and name filled in.
    func lostSignIn() {
        guard credential != nil else { return }
        forget()
    }

    private func forget() {
        DeviceCredentialStore(app: AppConfig.deviceApp).forgetPassword()
        credentialLock.lock(); cachedCredential = .some(nil); credentialLock.unlock()
        // saved answers belong to whoever was signed in (favorites, albums): another account starts afresh
        session.configuration.urlCache?.removeAllCachedResponses()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .iopixSignedOut, object: nil) }
    }

    /// Another process (the app, for an extension) may have signed in or out since: read the Keychain again.
    func reloadCredential() {
        credentialLock.lock(); cachedCredential = nil; credentialLock.unlock()
    }

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 6 * 3600  // a long video over a slow connection
        // the server tags its lists (ETag) and thumbnails: an unchanged list comes back as a short "not modified"
        cfg.urlCache = URLCache(memoryCapacity: 24 << 20, diskCapacity: 300 << 20,
                                directory: AppConfig.dataFolder.appendingPathComponent("HTTPCache", isDirectory: true))
        cfg.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /// A redirect to another host (a proxy's sign-in page, a misconfigured proxy) is not followed, so the app
    /// password and the service token never reach anyone but the server; `check` then reports a needed sign-in.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let from = (task.originalRequest?.url ?? server).host?.lowercased()
        completionHandler(request.url?.host?.lowercased() == from ? request : nil)
    }

    var server: URL { AppConfig.serverURL }

    /// Whether a URL is one of this app's servers: the address for apps or the home address.
    func isOurs(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == server.host?.lowercased() || host == AppConfig.homeURL?.host?.lowercased()
    }

    /// The headers a request to ioPix needs that are not made by `request` (a video player, a web image loader).
    var authHeaders: [String: String] { credential?.headers ?? [:] }

    func request(_ path: String, method: String = "GET") -> URLRequest {
        // a path may carry its own query ("face/12?v=3"): only the part before ? is a path
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        // the admin and maintenance calls go to the home address, when there is one (HomeServer)
        let base = HomeServer.isHomeOnly(parts[0], method: method) ? (AppConfig.homeURL ?? server) : server
        var url = base.appendingPathComponent(parts[0])
        if parts.count == 2, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.percentEncodedQuery = parts[1]
            url = c.url ?? url
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        if method != "GET" {
            lastWrite = Date()
        } else if Date().timeIntervalSince(lastWrite) < 20 {
            // right after a change, the server's "not modified" answers can lag it: read afresh for a little while
            r.cachePolicy = .reloadIgnoringLocalCacheData
        }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        // the server's own address, as a browser on the web app would send it: iopix hands it on to Google, whose
        // map key is usually restricted to that address (without it, place searches are refused as "referer <empty>")
        if let host = base.host, let scheme = base.scheme {
            r.setValue("\(scheme)://\(host)\(base.port.map { ":\($0)" } ?? "")/", forHTTPHeaderField: "Referer")
        }
        credential?.authorize(&r)
        ServiceToken.apply(to: &r)
        return r
    }

    /// The JSON answer, or the reason there is none. Cloudflare's sign-in shows up as a redirect to another
    /// host or as an HTML page instead of JSON.
    func check(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else { throw IopixError.server("The server did not answer.") }
        if http.url != nil, !isOurs(http.url) {
            throw IopixError.needsSignIn
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = json?["detail"] as? String
        let atHome = AppConfig.homeURL.map { http.url?.host?.lowercased() == $0.host?.lowercased() } ?? false
        let homeOnly = http.url.map { HomeServer.isHomeOnly(relative($0), method: "GET") || HomeServer.isHomeOnly(relative($0), method: "POST") } ?? false
        switch http.statusCode {
        case 404 where homeOnly && !atHome:  // an admin call at the address for apps, which does not serve it
            throw IopixError.homeOnly
        case 300..<400:  // a redirect that was not followed: another host wants a sign-in first
            throw IopixError.needsSignIn
        case 200..<300:
            if let json { return json }
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            throw type.contains("html") ? IopixError.needsSignIn : IopixError.server("The server sent an answer the app does not understand.")
        case 401:
            // the app password was removed (Settings › Account): the sign-in screen comes back. A refusal at the home
            // address (another server, perhaps) does not sign this device out.
            if !atHome { lostSignIn() }
            throw IopixError.needsSignIn
        case 403:
            throw json == nil ? IopixError.needsSignIn : IopixError.notAllowed(detail ?? "This account cannot add photos.")
        case 502, 503, 504:  // iopix is restarting or out of reach behind Cloudflare: worth trying again later
            throw URLError(.cannotConnectToHost)
        default:
            // a plain-text error (a crash in the server, or a proxy in front of it): its words and the request, so
            // the cause can be found; the app's log (Console, subsystem net.iothing.iopix) gets the whole answer
            let text = String(data: data.prefix(2000), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let what = "\(http.url.map { "\($0.path)" } ?? "the server") answered \(http.statusCode)"
            Self.log.error("\(what, privacy: .public): \(text, privacy: .public)")
            if let detail { throw IopixError.server(detail) }
            let snippet = text.contains("<") ? "" : String(text.prefix(200))
            throw IopixError.server("The server answered with error \(http.statusCode) for \(http.url?.path ?? "the request")\(snippet.isEmpty ? "." : ": \(snippet)")")
        }
    }

    static let log = Logger(subsystem: "net.iothing.iopix", category: "network")

    /// A URL's path below the address of the app ("api/photos"), as `request` takes it.
    private func relative(_ url: URL) -> String {
        var p = url.path
        for base in [server.path, AppConfig.homeURL?.path ?? ""] where base.count > 1 && p.hasPrefix(base) {
            p.removeFirst(base.count)
            break
        }
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    /// Network changed (home Wi-Fi to cellular): the next requests open new connections, by the new route.
    func networkMoved() {
        lastMove = Date()
        session.flush {}
    }

    /// When the device last moved to another network. For a little while after, a sign-in page in front of iopix
    /// can be the network still settling (old connections, a DNS answer from before), so it is checked again
    /// before anyone is asked to sign in.
    private(set) var lastMove = Date.distantPast
    var settling: Bool { Date().timeIntervalSince(lastMove) < 20 }

    func account() async throws -> Account {
        guard credential != nil else { throw IopixError.needsSignIn }  // nothing is asked without the app password
        let (data, resp) = try await session.data(for: request("api/auth/me"))
        let j = try check(data, resp)
        // api/auth/me answers everyone: not signed in with an app password sent means it is no longer good
        if j["signedIn"] as? Bool == false {
            lostSignIn()
            throw IopixError.needsSignIn
        }
        let user = j["user"] as? [String: Any]
        return Account(name: user?["name"] as? String,
                       signedIn: j["signedIn"] as? Bool ?? false,
                       canWrite: j["canWrite"] as? Bool ?? false,
                       isAdmin: j["isAdmin"] as? Bool ?? false,
                       person: (user?["person"] as? NSNumber)?.intValue)
    }

    /// Any JSON endpoint, as a dictionary.
    func json(_ path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        guard credential != nil else { throw IopixError.needsSignIn }  // nothing is asked without the app password
        var r = request(path)
        if !query.isEmpty, var c = URLComponents(url: r.url!, resolvingAgainstBaseURL: false) {
            c.queryItems = query
            // URLComponents leaves "+" as it is, and the server reads a bare "+" as a space
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            r.url = c.url
        }
        let (data, resp) = try await session.data(for: r)
        return try check(data, resp)
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

    /// Sends one file: staged first (iopix looks at it and checks for duplicates), then imported.
    /// When this app last changed something on the server (any request that was not a plain read).
    private var lastWrite = Date.distantPast

    /// A change made outside `request` (a background upload that finished later): reads skip the cache for a while.
    func noteWrite() { lastWrite = Date() }

    /// Whether this server takes a whole upload in one request and can say which files it already has
    /// (iopix 1.78 and later), learnt once per server address.
    private var modernServer: URL?
    private var modernKnown: Bool?

    private func modernImport() async -> Bool {
        if modernServer == server, let known = modernKnown { return known }
        var r = request("api/import/check", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(#"{"files":[]}"#.utf8)
        guard let (_, resp) = try? await session.data(for: r), let code = (resp as? HTTPURLResponse)?.statusCode else { return false }
        // 404 or 405: an older server. Anything else (200, or a sign-in wanted) means the route is there.
        let known = code != 404 && code != 405
        if code != 401 { modernServer = server; modernKnown = known }
        return known
    }

    /// The file's size and SHA-256, read in pieces (a long video is never held in memory).
    static func fingerprint(_ file: URL) throws -> (size: Int, sha256: String) {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        var size = 0
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += chunk.count
        }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Which of these files the library already has (by size and SHA-256). Empty on an older server.
    func alreadyThere(_ files: [(size: Int, sha256: String)]) async -> Set<String> {
        guard !files.isEmpty, await modernImport() else { return [] }
        var r = request("api/import/check", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["files": files.map { ["size": $0.size, "sha256": $0.sha256] }])
        guard let (data, resp) = try? await session.data(for: r), let j = try? check(data, resp) else { return [] }
        return Set((j["present"] as? [[String: Any]] ?? []).compactMap { $0["sha256"] as? String })
    }

    func upload(file: URL, name: String, to destination: Destination = .current, progress: @escaping (Double) -> Void) async throws -> UploadOutcome {
        if destination.needsPatterns {
            if patternSupport != true { _ = try await layouts() }
            // an older server would ignore the pattern and use its own layout: better not to send than to misfile
            guard patternSupport == true else { throw IopixError.needsServerUpdate }
        }
        if await modernImport() {
            return try await uploadInOne(file: file, name: name, to: destination, progress: progress)
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
            return .skipped(s["reason"] as? String ?? "ioPix did not add it.")
        }
        return .skipped("ioPix did not add it.")
    }

    /// An upload ready to hand to a background session: the request and its body on disk.
    enum PreparedUpload {
        case alreadyThere
        case request(URLRequest, body: URL)
    }

    /// For iopix 1.78 and later (nil on an older server): checks whether the library already has the file, else
    /// writes the one-request upload body into `folder` (a place that outlives this process, for background sending).
    func prepareUpload(file: URL, name: String, to destination: Destination = .current, folder: URL) async throws -> PreparedUpload? {
        if destination.needsPatterns {
            if patternSupport != true { _ = try await layouts() }
            guard patternSupport == true else { throw IopixError.needsServerUpdate }
        }
        guard await modernImport() else { return nil }
        if let print = try? Self.fingerprint(file), await alreadyThere([print]).contains(print.sha256) { return .alreadyThere }
        var fields = ["duplicates": "skip"]
        for (k, v) in destination.runFields { fields[k] = "\(v)" }
        let boundary = "iopix-\(UUID().uuidString)"
        let body = try Multipart.write(file: file, name: name, boundary: boundary, fields: fields, into: folder)
        var r = request("api/import", method: "POST")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // a background session sends from another process: the app password goes with the request itself (request())
        return .request(r, body: body)
    }

    /// What the server did with a one-request upload.
    func outcome(_ data: Data, _ resp: URLResponse) throws -> UploadOutcome {
        if (resp as? HTTPURLResponse)?.statusCode == 409 {
            throw URLError(.resourceUnavailable)  // digiKam has the library open: nothing was kept, try again later
        }
        let result = try check(data, resp)
        if let added = result["added"] as? [Any], !added.isEmpty { return .added }
        if let s = (result["skipped"] as? [[String: Any]])?.first {
            if s["duplicate_of"] != nil && !(s["duplicate_of"] is NSNull) { return .alreadyThere }
            return .skipped(s["reason"] as? String ?? "ioPix did not add it.")
        }
        return .skipped("ioPix did not add it.")
    }

    /// iopix 1.78 and later: asks first whether the library already has the file (nothing is sent then), else sends
    /// it with the import choices in one request.
    private func uploadInOne(file: URL, name: String, to destination: Destination, progress: @escaping (Double) -> Void) async throws -> UploadOutcome {
        if let print = try? Self.fingerprint(file), await alreadyThere([print]).contains(print.sha256) {
            progress(1)
            return .alreadyThere
        }
        var fields = ["duplicates": "skip"]
        for (k, v) in destination.runFields { fields[k] = "\(v)" }
        let boundary = "iopix-\(UUID().uuidString)"
        let body = try Multipart.write(file: file, name: name, boundary: boundary, fields: fields)
        defer { try? FileManager.default.removeItem(at: body) }
        var r = request("api/import", method: "POST")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.upload(for: r, fromFile: body, delegate: ProgressDelegate(progress))
        return try outcome(data, resp)
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
    static func write(file: URL, name: String, boundary: String, fields: [String: String] = [:], into folder: URL? = nil) throws -> URL {
        let out = (folder ?? FileManager.default.temporaryDirectory).appendingPathComponent("upload-\(UUID().uuidString)")
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
            for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
                try sink.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
            }
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

extension Notification.Name {
    /// This device signed in (the sign-in screen), or lost its app password (signed out, or refused by the server).
    static let iopixSignedIn = Notification.Name("iopixSignedIn")
    static let iopixSignedOut = Notification.Name("iopixSignedOut")
}
