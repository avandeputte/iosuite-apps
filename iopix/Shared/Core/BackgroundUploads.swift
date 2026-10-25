#if os(iOS)
import Foundation

/// Sending that carries on after the app or the share sheet has gone: iOS keeps background uploads going and tells
/// whichever process is around when they finish. Needs iopix 1.78 or later (one request per photo).
final class BackgroundUploads: NSObject, URLSessionDataDelegate {
    /// The app's own queue.
    static let appIdentifier = "net.iothing.iopix.uploads"
    /// The share sheet's (a separate process: its own session, which iOS hands to the app if the sheet has gone).
    static let shareIdentifier = "net.iothing.iopix.share"

    private static var sessions: [String: BackgroundUploads] = [:]
    private static let lock = NSLock()

    /// The uploader for an identifier, made on first use (also when iOS wakes the app for its events).
    static func shared(_ identifier: String) -> BackgroundUploads {
        lock.lock(); defer { lock.unlock() }
        if let s = sessions[identifier] { return s }
        let s = BackgroundUploads(identifier)
        sessions[identifier] = s
        return s
    }

    /// Bodies waiting to be sent live here (the App Group, so they outlive the share sheet).
    static var outbox: URL {
        let u = AppConfig.dataFolder.appendingPathComponent("Outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A finished upload: what it was (the task's description: the queue item's id, or the file name for the share
    /// sheet) and what came of it. Set by the app; without it (the share sheet) results go to `log`.
    static var onFinish: ((_ tag: String, _ result: Result<UploadOutcome, Error>) -> Void)?
    /// iOS's "done" for a session that woke the app.
    static var wakeHandlers: [String: () -> Void] = [:]
    /// Progress of uploads in flight, by tag.
    static var onProgress: ((_ tag: String, _ fraction: Double) -> Void)?

    let identifier: String
    private(set) var session: URLSession!
    private var received: [Int: Data] = [:]
    private var bodies: [Int: URL] = [:]
    private let queue = OperationQueue()

    private init(_ identifier: String) {
        self.identifier = identifier
        super.init()
        queue.maxConcurrentOperationCount = 1
        let cfg = URLSessionConfiguration.background(withIdentifier: identifier)
        if AppConfig.hasGroup { cfg.sharedContainerIdentifier = AppConfig.appGroup }
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
    }

    /// Starts sending `body` (removed once sent). `tag` comes back with the result.
    func send(_ request: URLRequest, body: URL, tag: String) {
        let task = session.uploadTask(with: request, fromFile: body)
        task.taskDescription = tag
        queue.addOperation { self.bodies[task.taskIdentifier] = body }
        task.resume()
    }

    /// The tags of uploads still under way.
    func inFlight() async -> Set<String> {
        let tasks = await session.allTasks
        return Set(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
    }

    // MARK: URLSession

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0, let tag = task.taskDescription else { return }
        let f = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        DispatchQueue.main.async { Self.onProgress?(tag, f) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data = received.removeValue(forKey: task.taskIdentifier) ?? Data()
        if let body = bodies.removeValue(forKey: task.taskIdentifier) { try? FileManager.default.removeItem(at: body) }
        let tag = task.taskDescription ?? ""
        let result: Result<UploadOutcome, Error>
        if let error {
            result = .failure(error)
        } else if let resp = task.response {
            result = Result { try IopixClient.shared.outcome(data, resp) }
        } else {
            result = .failure(URLError(.badServerResponse))
        }
        DispatchQueue.main.async {
            if let handler = Self.onFinish { handler(tag, result) } else { Self.log(tag, result) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let id = identifier
        DispatchQueue.main.async {
            Self.wakeHandlers.removeValue(forKey: id)?()
        }
    }

    // MARK: results the app wasn't there for

    struct Logged: Codable {
        let tag: String
        let outcome: String   // added, already, skipped, failed
        let message: String?
        let at: Date
    }

    private static var logFile: URL { AppConfig.dataFolder.appendingPathComponent("background-results.json") }

    /// Kept for the app to pick up (the share sheet's results).
    static func log(_ tag: String, _ result: Result<UploadOutcome, Error>) {
        var list = (try? JSONDecoder().decode([Logged].self, from: Data(contentsOf: logFile))) ?? []
        let entry: Logged
        switch result {
        case .success(.added): entry = Logged(tag: tag, outcome: "added", message: nil, at: Date())
        case .success(.alreadyThere): entry = Logged(tag: tag, outcome: "already", message: nil, at: Date())
        case .success(.skipped(let why)): entry = Logged(tag: tag, outcome: "skipped", message: why, at: Date())
        case .failure(let e): entry = Logged(tag: tag, outcome: "failed", message: e.localizedDescription, at: Date())
        }
        list.append(entry)
        try? JSONEncoder().encode(Array(list.suffix(200))).write(to: logFile, options: .atomic)
    }

    /// Takes the results left by the share sheet (they are removed from the log).
    static func takeLogged() -> [Logged] {
        guard let data = try? Data(contentsOf: logFile), let list = try? JSONDecoder().decode([Logged].self, from: data) else { return [] }
        try? FileManager.default.removeItem(at: logFile)
        return list
    }
}
#endif
