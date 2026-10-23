import Foundation

/// Who this device is signed in as on iopix.
struct Account: Equatable {
    var name: String?
    var signedIn: Bool
    var canWrite: Bool
}

/// What became of one file sent to iopix.
enum UploadOutcome: Equatable {
    case added
    case alreadyThere
    case skipped(String)
}

enum IopixError: LocalizedError, Equatable {
    case needsSignIn
    case notAllowed(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .needsSignIn: return "Sign in to iopix to send photos."
        case .notAllowed(let why): return why
        case .server(let why): return why
        }
    }
}

/// Talks to iopix the way its web app does: the sign-in cookies (iopix's own session and, from outside,
/// Cloudflare Access's), then the import endpoints, which put each file in the library's dated folders
/// and skip anything already there. The server does every write; the apps only send files.
final class IopixClient: NSObject {
    static let shared = IopixClient()

    let session: URLSession

    override init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = AppConfig.cookies
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 6 * 3600  // a long video over a slow connection
        session = URLSession(configuration: cfg)
    }

    var server: URL { AppConfig.serverURL }

    func request(_ path: String, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: server.appendingPathComponent(path))
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

    func account() async throws -> Account {
        let (data, resp) = try await session.data(for: request("api/auth/me"))
        let j = try check(data, resp)
        let user = j["user"] as? [String: Any]
        return Account(name: user?["name"] as? String,
                       signedIn: j["signedIn"] as? Bool ?? false,
                       canWrite: j["canWrite"] as? Bool ?? false)
    }

    func signOut() async {
        _ = try? await session.data(for: request("api/auth/logout", method: "POST"))
        forgetCookies()
    }

    func forgetCookies() {
        let host = server.host?.lowercased() ?? ""
        for c in AppConfig.cookies.cookies ?? [] where host.hasSuffix(c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            AppConfig.cookies.deleteCookie(c)
        }
    }

    /// Sends one file: staged first (iopix looks at it and checks for duplicates), then imported.
    func upload(file: URL, name: String, progress: @escaping (Double) -> Void) async throws -> UploadOutcome {
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
        run.httpBody = try JSONSerialization.data(withJSONObject: ["duplicates": "skip"])
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
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let sink = try FileHandle(forWritingTo: out)
        defer { try? sink.close() }
        let safe = name.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        sink.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(safe)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        let source = try FileHandle(forReadingFrom: file)
        defer { try? source.close() }
        while let chunk = try source.read(upToCount: 4 << 20), !chunk.isEmpty {
            sink.write(chunk)
        }
        sink.write(Data("\r\n--\(boundary)--\r\n".utf8))
        return out
    }
}
