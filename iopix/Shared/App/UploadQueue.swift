import Foundation
#if os(iOS)
import UIKit
#endif

struct UploadItem: Codable, Identifiable, Equatable {
    enum Source: Codable, Equatable {
        case file(String)   // a copy kept in the queue folder (name relative to it)
        case asset(String)  // a photo in the Photos library, read when it is its turn
    }
    enum State: String, Codable {
        case review    // found in the Photos library, waiting for a send-or-ignore decision
        case waiting, sending, done, duplicate, failed

        init(from decoder: Decoder) throws {  // a state this version does not know: treat as waiting
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .waiting
        }
    }

    var id = UUID()
    var name: String
    var source: Source
    var state: State = .waiting
    var message: String?
    var attempts = 0
    var added = Date()
    var progress: Double = 0

    var stateText: String {
        switch state {
        case .review: return "New"
        case .waiting: return message ?? "Waiting"
        case .sending: return "Sending"
        case .done: return "In iopix"
        case .duplicate: return "Already in iopix"
        case .failed: return message ?? "Not sent"
        }
    }
}

/// Files and photos waiting to go to iopix, sent one at a time. The list is kept on disk, so nothing is lost
/// when the app quits; a file stays in the queue until iopix has it.
@MainActor
final class UploadQueue: ObservableObject {
    static let shared = UploadQueue()

    @Published private(set) var items: [UploadItem] = []
    @Published private(set) var account: Account?
    @Published private(set) var needsSignIn = false
    @Published private(set) var offline = false
    @Published private(set) var blocked: String?  // why nothing is sent right now, besides sign-in

    private var running = false
    private var retry: Task<Void, Never>?
    private let listFile = AppConfig.dataFolder.appendingPathComponent("queue.json")
    private let filesFolder = AppConfig.dataFolder.appendingPathComponent("Queue", isDirectory: true)

    var pending: [UploadItem] { items.filter { $0.state == .waiting || $0.state == .sending } }
    var current: UploadItem? { items.first { $0.state == .sending } }
    var finished: [UploadItem] { items.filter { [.done, .duplicate, .failed].contains($0.state) }.reversed() }
    /// New photos from the library that wait for a decision.
    var reviewing: [UploadItem] { items.filter { $0.state == .review } }
    var canSend: Bool { account?.canWrite == true }

    init() {
        try? FileManager.default.createDirectory(at: filesFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: listFile) {
            // item by item, so one entry a newer or older version wrote differently does not lose the whole list
            if let saved = try? JSONDecoder().decode([Lossy<UploadItem>].self, from: data) {
                // on iPhone an item may still be on its way in the background: startBackground() looks before resetting it
                #if os(iOS)
                items = saved.compactMap(\.value).map { var i = $0; i.progress = 0; return i }
                #else
                items = saved.compactMap(\.value).map { var i = $0; if i.state == .sending { i.state = .waiting }; i.progress = 0; return i }
                #endif
            } else {
                try? FileManager.default.moveItem(at: listFile, to: listFile.appendingPathExtension("bad"))
            }
        }
        // copies left in the queue folder by a crash between copy and save
        let keep = Set(items.compactMap { if case .file(let rel) = $0.source, !rel.isEmpty { return String(rel.split(separator: "/")[0]) } else { return nil } })
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: filesFolder.path)) ?? [] where !keep.contains(dir) {
            try? FileManager.default.removeItem(at: filesFolder.appendingPathComponent(dir))
        }
    }

    // MARK: adding

    /// Copies (or moves) files into the queue folder, so they can be sent later even if the originals go away.
    /// Where a queued file is kept (for showing it before it is sent).
    func fileURL(_ rel: String) -> URL { filesFolder.appendingPathComponent(rel) }

    func add(files: [URL], move: Bool = false, review: Bool = false) {
        for url in files {
            let id = UUID()
            let dir = filesFolder.appendingPathComponent(id.uuidString, isDirectory: true)
            let dst = dir.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if move {
                    try FileManager.default.moveItem(at: url, to: dst)
                    Self.removeIfEmptyTemp(url.deletingLastPathComponent())
                } else {
                    try FileManager.default.copyItem(at: url, to: dst)
                }
                items.append(UploadItem(id: id, name: url.lastPathComponent, source: .file("\(id.uuidString)/\(url.lastPathComponent)"),
                                        state: review ? .review : .waiting))
            } catch {
                try? FileManager.default.removeItem(at: dir)
                items.append(UploadItem(id: id, name: url.lastPathComponent, source: .file(""), state: .failed, message: "Could not read the file"))
            }
        }
        save()
        kick()
    }

    /// Photos from the library: held for review (they are sent only once picked) unless `review` is false.
    func add(assets: [(id: String, name: String)], review: Bool = true) {
        let queued = Set(items.compactMap { if case .asset(let a) = $0.source, [.review, .waiting, .sending].contains($0.state) { return a } else { return nil } })
        for a in assets where !queued.contains(a.id) {
            items.append(UploadItem(name: a.name, source: .asset(a.id), state: review ? .review : .waiting))
        }
        save()
        kick()
        if review { Task { await ReviewSync.shared.apply() } }  // already picked or ignored on another device?
    }

    func send(_ ids: Set<UUID>) {
        ReviewSync.shared.decided(localIDs: reviewAssets(ids))
        for i in items.indices where items[i].state == .review && ids.contains(items[i].id) { items[i].state = .waiting }
        save()
        kick()
    }

    /// Ignored photos leave the list; they stay counted as seen, so they do not come back.
    func ignore(_ ids: Set<UUID>) {
        ReviewSync.shared.decided(localIDs: reviewAssets(ids))
        for item in items where item.state == .review && ids.contains(item.id) { removeStoredFile(item) }
        items.removeAll { $0.state == .review && ids.contains($0.id) }
        save()
    }

    /// The Photos library ids of the photos waiting for a send-or-ignore decision.
    var reviewAssetIDs: [String] {
        items.compactMap { if $0.state == .review, case .asset(let a) = $0.source { return a } else { return nil } }
    }

    /// Photos picked or ignored on another device: they leave the review list here without being sent.
    func dropReview(localIDs: Set<String>) {
        let before = items.count
        items.removeAll { if $0.state == .review, case .asset(let a) = $0.source { return localIDs.contains(a) } else { return false } }
        if items.count != before { save() }
    }

    private func reviewAssets(_ ids: Set<UUID>) -> [String] {
        items.compactMap { if $0.state == .review, ids.contains($0.id), case .asset(let a) = $0.source { return a } else { return nil } }
    }

    func retryFailed() {
        for i in items.indices where items[i].state == .failed && items[i].source != .file("") {
            items[i].state = .waiting
            items[i].attempts = 0
            items[i].message = nil
        }
        save()
        kick()
    }

    func clearFinished() {
        for item in items where item.state == .failed { removeStoredFile(item) }
        items.removeAll { $0.state == .done || $0.state == .duplicate || $0.state == .failed }
        save()
    }

    // MARK: sending

    func refreshAccount() async {
        do {
            account = try await IopixClient.shared.account()
            needsSignIn = !(account?.canWrite ?? false)
            offline = false
        } catch IopixError.needsSignIn {
            account = Account(name: nil, signedIn: false, canWrite: false)
            needsSignIn = true
        } catch {
            offline = true
        }
        if canSend { kick() }
    }

    func kick() {
        guard !running, items.contains(where: { $0.state == .waiting }) else { return }
        running = true
        Task { await run() }
    }

    private func run() async {
        #if os(iOS)
        // iOS allows a short while in the background; when that runs out the upload in flight is stopped and the
        // item stays waiting, so it starts again the next time the app is open (nothing is lost, just time)
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "iopix uploads") { [weak self] in
            Task { @MainActor in self?.backgroundTimeRanOut() }
        }
        defer { endBackgroundTask() }
        #endif
        defer { running = false }
        blocked = nil
        if !canSend { await refreshAccount() }
        guard canSend else {
            // started offline (a Mac at login before Wi-Fi is up): look again in a minute
            if offline, items.contains(where: { $0.state == .waiting }) { scheduleRetry(after: 60) }
            return
        }
        var sent = 0
        defer { if sent > 0 { NotificationCenter.default.post(name: .iopixUploadsDone, object: nil, userInfo: ["count": sent]) } }

        while let idx = items.firstIndex(where: { $0.state == .waiting }) {
            let id = items[idx].id
            update(id) { $0.state = .sending; $0.progress = 0; $0.message = nil }
            let item = items[idx]
            do {
                let (file, cleanup) = try await prepare(item)
                defer { cleanup() }
                #if os(iOS)
                // iopix 1.78 and later: hand the photo to iOS, which keeps sending it after the app is put away
                if let prepared = try await IopixClient.shared.prepareUpload(file: file, name: item.name, folder: BackgroundUploads.outbox) {
                    switch prepared {
                    case .alreadyThere:
                        update(id) { $0.state = .duplicate }
                        if let done = items.first(where: { $0.id == id }) { removeStoredFile(done) }
                    case .request(let request, let body):
                        update(id) { $0.message = "Sending" }
                        BackgroundUploads.shared(BackgroundUploads.appIdentifier).send(request, body: body, tag: id.uuidString)
                    }
                    offline = false
                    continue
                }
                #endif
                let task = Task { try await IopixClient.shared.upload(file: file, name: item.name) { p in
                    Task { @MainActor in self.update(id, save: false) { $0.progress = p } }
                } }
                upload = task
                defer { upload = nil }
                let outcome = try await task.value
                update(id) {
                    switch outcome {
                    case .added: $0.state = .done; sent += 1
                    case .alreadyThere: $0.state = .duplicate
                    case .skipped(let why): $0.state = .failed; $0.message = why
                    }
                }
                if let done = items.first(where: { $0.id == id }), done.state != .failed { removeStoredFile(done) }
                offline = false
            } catch IopixError.needsServerUpdate {
                update(id) { $0.state = .waiting }
                blocked = IopixError.needsServerUpdate.localizedDescription
                return
            } catch IopixError.needsSignIn {
                update(id) { $0.state = .waiting }
                needsSignIn = true
                account = Account(name: nil, signedIn: false, canWrite: false)
                return
            } catch let e as IopixError {
                update(id) { $0.attempts += 1; $0.state = .failed; $0.message = e.localizedDescription }
            } catch let e as PhotoLibrary.Gone {
                update(id) { $0.state = .failed; $0.message = e.localizedDescription }
            } catch is CancellationError {
                update(id) { $0.state = .waiting; $0.message = "Continues when iopix is open" }
                return
            } catch let e where !(e is URLError) && (e as NSError).domain != NSURLErrorDomain && (e as NSError).domain != NSPOSIXErrorDomain {
                // the file itself (unreadable copy, a photo iCloud will not give, no space): this item, not the connection
                update(id) { $0.state = .failed; $0.message = Self.plain(e) }
            } catch {
                // no connection, or the server is restarting: try again later, give up after a few rounds
                let tries = (items.first { $0.id == id }?.attempts ?? 0) + 1
                update(id) {
                    $0.attempts = tries
                    $0.state = tries >= 6 ? .failed : .waiting
                    $0.message = tries >= 6 ? "Could not reach iopix" : "Waiting for a connection"
                }
                offline = true
                scheduleRetry(after: Double(min(tries, 5)) * 60)
                return
            }
        }
        trimHistory()
    }

    #if os(iOS)
    /// At launch: takes the results of background sending (also the share sheet's), and puts back in line the items
    /// that were being sent but that iOS no longer has.
    func startBackground() {
        BackgroundUploads.onFinish = { [weak self] tag, result in self?.finishedInBackground(tag, result) }
        BackgroundUploads.onProgress = { [weak self] tag, f in
            guard let self, let id = UUID(uuidString: tag) else { return }
            self.update(id, save: false) { $0.progress = f }
        }
        for logged in BackgroundUploads.takeLogged() { recordShared(logged) }
        _ = BackgroundUploads.shared(BackgroundUploads.shareIdentifier)  // its finished uploads come here now
        let app = BackgroundUploads.shared(BackgroundUploads.appIdentifier)
        Task {
            let going = await app.inFlight()
            var changed = false
            for i in items.indices where items[i].state == .sending && !going.contains(items[i].id.uuidString) {
                items[i].state = .waiting
                changed = true
            }
            if changed { save() }
            kick()
        }
    }

    private func finishedInBackground(_ tag: String, _ result: Result<UploadOutcome, Error>) {
        guard let id = UUID(uuidString: tag), items.contains(where: { $0.id == id }) else {
            // the share sheet's: shown in the list as done
            switch result {
            case .success(let o): recordShared(.init(tag: tag, outcome: o == .added ? "added" : o == .alreadyThere ? "already" : "skipped", message: nil, at: Date()))
            case .failure(let e): recordShared(.init(tag: tag, outcome: "failed", message: e.localizedDescription, at: Date()))
            }
            return
        }
        switch result {
        case .success(let o):
            update(id) {
                $0.message = nil
                switch o {
                case .added: $0.state = .done
                case .alreadyThere: $0.state = .duplicate
                case .skipped(let why): $0.state = .failed; $0.message = why
                }
                $0.progress = 1
            }
            if let done = items.first(where: { $0.id == id }), done.state != .failed { removeStoredFile(done) }
            if case .added = o { NotificationCenter.default.post(name: .iopixUploadsDone, object: nil, userInfo: ["count": 1]) }
        case .failure(let e):
            // no connection, the server restarting, or digiKam busy: back in line for a later try
            let tries = (items.first { $0.id == id }?.attempts ?? 0) + 1
            update(id) {
                $0.attempts = tries
                $0.state = tries >= 6 ? .failed : .waiting
                $0.message = tries >= 6 ? Self.plain(e) : "Waiting for a connection"
            }
            if tries < 6 { scheduleRetry(after: Double(min(tries, 5)) * 60) }
        }
        trimHistory()
        save()
    }

    /// A photo sent from the share sheet, added to the list as finished.
    private func recordShared(_ l: BackgroundUploads.Logged) {
        let state: UploadItem.State = l.outcome == "added" ? .done : l.outcome == "already" ? .duplicate : .failed
        items.append(UploadItem(name: l.tag, source: .file(""), state: state, message: l.message))
        trimHistory()
        save()
    }
    #endif

    private func prepare(_ item: UploadItem) async throws -> (URL, () -> Void) {
        switch item.source {
        case .file(let rel):
            return (filesFolder.appendingPathComponent(rel), {})
        case .asset(let localID):
            let url = try await PhotoLibrary.export(localID)
            return (url, { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) })
        }
    }

    /// The upload in flight, so a background time-out can stop it.
    private var upload: Task<UploadOutcome, Error>?

    #if os(iOS)
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private func backgroundTimeRanOut() {
        upload?.cancel()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }
    #endif

    private static func plain(_ e: Error) -> String {
        let ns = e as NSError
        if ns.domain == "PHPhotosErrorDomain" {
            switch ns.code {
            case 3164: return "Not enough free space to get this photo from iCloud"
            case 3165: return "This photo is in iCloud and needs a connection to get"
            default: break
            }
        }
        return e.localizedDescription
    }

    private func scheduleRetry(after seconds: Double) {
        retry?.cancel()
        retry = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { kick() }
        }
    }

    // MARK: bookkeeping

    /// The per-file folders the pickers and the share sheet make in the temporary directory, once emptied.
    private static func removeIfEmptyTemp(_ dir: URL) {
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard dir.standardizedFileURL.path.hasPrefix(tmp), dir.standardizedFileURL.path != tmp,
              (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    private func update(_ id: UUID, save shouldSave: Bool = true, _ change: (inout UploadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        if shouldSave { save() }
    }

    private func removeStoredFile(_ item: UploadItem) {
        if case .file(let rel) = item.source, !rel.isEmpty {
            try? FileManager.default.removeItem(at: filesFolder.appendingPathComponent(rel).deletingLastPathComponent())
        }
    }

    /// Keeps the last 200 finished items for the list; older ones are dropped.
    private func trimHistory() {
        let done = items.filter { $0.state == .done || $0.state == .duplicate || $0.state == .failed }
        if done.count > 200 {
            let drop = Set(done.prefix(done.count - 200).map(\.id))
            items.removeAll { drop.contains($0.id) }
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: listFile, options: .atomic) }
    }
}

extension Notification.Name {
    /// A run of uploads finished; userInfo["count"] is how many photos iopix added.
    static let iopixUploadsDone = Notification.Name("iopixUploadsDone")
}

/// Decodes to nil instead of failing the whole list.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) { value = try? T(from: decoder) }
}
