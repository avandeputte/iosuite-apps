import Foundation
import Network

/// Syncing with the ionotes server. Changes made here are saved locally first and marked dirty; a sync sends
/// them (POST /api/sync/push), uploads new pictures, then fetches everything changed on the server since the
/// last rev (GET /api/sync), and finally fetches pictures this device doesn't have yet. It runs on launch, when
/// the app comes to the front, shortly after an edit, every minute while active, and when the network returns.
/// An edit made here and not sent yet always wins over the server's copy until the server has seen it; the
/// server then decides by edit time ("stale": its copy is newer and is kept).
extension NotesStore {
    private static let pollInterval: TimeInterval = 60

    func startSync() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
        setActive(true)
        Task { await refreshAccount() }  // who is signed in, for Settings
    }

    /// Back online (or onto another network): new connections, and a sync.
    private func networkChanged(online: Bool) {
        defer { wasOnline = online }
        guard online, !wasOnline else { return }
        client.session.flush {}
        syncSoon(after: 1)
    }

    /// Every minute while the app is in use (on the Mac, as long as it runs in the menu bar).
    func setActive(_ active: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        guard active else { return }
        syncSoon(after: 0)
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon(after: 0) }
        }
    }

    /// Syncs in a moment; more edits in the meantime push it back, so typing sends one change, not many.
    func syncSoon(after delay: TimeInterval = 2) {
        syncTask?.cancel()
        syncTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            // a sync of its own, so a later syncSoon only cancels the wait, never a sync under way
            Task { await self.sync() }
        }
    }

    /// Sends what changed here and fetches what changed on the server.
    func sync() async {
        guard ServerConfig.serverURL != nil else {
            syncStatus = .notConfigured
            return
        }
        if syncing {
            syncAgain = true
            return
        }
        syncing = true
        if syncStatus != .synced { syncStatus = .syncing }
        defer {
            syncing = false
            pendingChanges = (try? db.pendingCount()) ?? pendingChanges
            if syncAgain {
                syncAgain = false
                syncSoon(after: 0.5)
            }
        }
        var refused: String?
        do {
            do {
                try await pushChanges()
                try await uploadImages()
            } catch IonotesError.notAllowed(let why) {
                refused = why  // a read-only account: still fetch what others changed
            }
            try await pull()
            lastSync = Date()
            syncStatus = refused.map { .failed($0) } ?? .synced
        } catch IonotesError.needsSignIn {
            syncStatus = .signedOut
            account = nil
        } catch let error as URLError {
            syncStatus = .offline(error.localizedDescription)
        } catch {
            syncStatus = .failed(error.localizedDescription)
        }
        if syncStatus == .synced || refused != nil {
            Task { await downloadImages() }
        }
    }

    // MARK: - Sending

    private func pushChanges() async throws {
        let notes = try db.dirtyNotes()
        let folders = try db.dirtyFolders()
        let tags = try db.dirtyTags()
        guard !notes.isEmpty || !folders.isEmpty || !tags.isEmpty else { return }

        let noteDicts: [[String: Any]] = notes.map { item in
            let n = item.note
            if item.deleted {
                return ["id": n.id, "deleted": true, "updatedAt": n.updatedAt.timeIntervalSince1970]
            }
            return ["id": n.id, "title": n.title, "body": n.body, "ocrText": n.ocrText, "source": n.source,
                    "sourceApp": n.sourceApp as Any? ?? NSNull(), "createdAt": n.createdAt.timeIntervalSince1970,
                    "updatedAt": n.updatedAt.timeIntervalSince1970, "tags": n.tags, "pinned": n.pinned,
                    "folderID": n.folderID as Any? ?? NSNull(), "deleted": false]
        }
        let folderDicts: [[String: Any]] = folders.map {
            ["id": $0.id, "name": $0.name, "color": $0.color as Any? ?? NSNull(), "createdAt": $0.createdAt,
             "updatedAt": $0.updatedAt, "deleted": $0.deleted]
        }
        let tagDicts: [[String: Any]] = tags.map {
            ["name": $0.name, "color": $0.color as Any? ?? NSNull(), "updatedAt": $0.updatedAt]
        }
        let answer = try await client.push(notes: noteDicts, folders: folderDicts, tags: tagDicts)
        let rev = (answer["rev"] as? NSNumber)?.int64Value ?? 0

        try db.transaction {
            for (sent, result) in zip(folders, answer["folders"] as? [[String: Any]] ?? []) {
                switch result["status"] as? String {
                case "ok":
                    try db.markFolderSent(id: sent.id, updatedAt: sent.updatedAt)
                case "stale":
                    if let item = result["item"] as? [String: Any] { try applyFolder(item, force: true) }
                default:
                    IonotesClient.log.error("folder \(sent.id, privacy: .public) refused: \(String(describing: result["error"]), privacy: .public)")
                }
            }
            for (sent, result) in zip(notes, answer["notes"] as? [[String: Any]] ?? []) {
                let id = sent.note.id, sentAt = sent.note.updatedAt.timeIntervalSince1970
                switch result["status"] as? String {
                case "ok":
                    let item = result["item"] as? [String: Any] ?? [:]
                    if sent.deleted {
                        if let state = try db.syncState(ofNote: id), state.deleted, state.updatedAt == sentAt {
                            try db.removeNote(id: id)
                        }
                    } else {
                        try db.markSent(id: id, updatedAt: sentAt, rev: (item["rev"] as? NSNumber)?.int64Value ?? rev,
                                        imageSHA: item["imageSHA"] as? String, hasImage: item["hasImage"] as? Bool ?? false)
                    }
                case "stale":
                    if let item = result["item"] as? [String: Any] { try applyNote(item, force: true) }
                default:
                    IonotesClient.log.error("note \(id, privacy: .public) refused: \(String(describing: result["error"]), privacy: .public)")
                }
            }
            for (sent, result) in zip(tags, answer["tags"] as? [[String: Any]] ?? []) {
                switch result["status"] as? String {
                case "ok":
                    try db.markTagSent(name: sent.name, updatedAt: sent.updatedAt)
                case "stale":
                    if let item = result["item"] as? [String: Any] { try applyTag(item, force: true) }
                default:
                    break
                }
            }
        }
        reloadNotes()
    }

    /// Pictures made here, sent once their notes are on the server.
    private func uploadImages() async throws {
        for id in try db.pendingImageUploads() {
            guard let data = try? Data(contentsOf: AppPaths.noteImageURL(id)) else {
                try db.setImageState(id: id, local: nil, pending: false)
                continue
            }
            do {
                let note = try await client.uploadImage(data, noteID: id)
                try db.setImageUploaded(id: id, sha: note["imageSHA"] as? String, rev: (note["rev"] as? NSNumber)?.int64Value ?? 0)
            } catch IonotesError.notAllowed(let why) where why.lowercased().contains("image") {
                // not a picture the server can read, or too large: keep it here, stop trying
                try db.setImageState(id: id, local: "local-\(id)", pending: false)
                lastError = "A picture could not be sent to the server: \(why)"
            }
        }
        reloadNotes()
    }

    // MARK: - Fetching

    private func pull() async throws {
        var since = Int64(try db.meta("rev") ?? "") ?? 0
        while true {
            let page = try await client.changes(since: since)
            try db.transaction {
                for item in page["folders"] as? [[String: Any]] ?? [] { try applyFolder(item, force: false) }
                for item in page["notes"] as? [[String: Any]] ?? [] { try applyNote(item, force: false) }
                for item in page["tags"] as? [[String: Any]] ?? [] { try applyTag(item, force: false) }
                since = (page["rev"] as? NSNumber)?.int64Value ?? since
                try db.setMeta("rev", String(since))
            }
            guard page["more"] as? Bool == true else { break }
        }
        reloadNotes()
    }

    /// The server's copy of a note. Unless `force` (the server refused our edit as older), a change made here
    /// and not sent yet is kept.
    private func applyNote(_ item: [String: Any], force: Bool) throws {
        guard let id = item["id"] as? String else { return }
        let local = try db.syncState(ofNote: id)
        if let local, local.dirty, !force { return }
        if item["deleted"] as? Bool == true {
            if local != nil {
                try db.removeNote(id: id)
                try? FileManager.default.removeItem(at: AppPaths.noteImageURL(id))
            }
            return
        }
        let pending = local?.imagePending == true
        let note = Note(id: id,
                        title: item["title"] as? String ?? "",
                        body: item["body"] as? String ?? "",
                        ocrText: item["ocrText"] as? String ?? "",
                        hasImage: (item["hasImage"] as? Bool ?? false) || pending,
                        source: item["source"] as? String ?? "manual",
                        sourceApp: item["sourceApp"] as? String,
                        createdAt: Date(timeIntervalSince1970: (item["createdAt"] as? NSNumber)?.doubleValue ?? 0),
                        updatedAt: Date(timeIntervalSince1970: (item["updatedAt"] as? NSNumber)?.doubleValue ?? 0),
                        tags: item["tags"] as? [String] ?? [],
                        pinned: item["pinned"] as? Bool ?? false,
                        folderID: item["folderID"] as? String)
        try db.saveFromServer(note, imageSHA: item["imageSHA"] as? String, rev: (item["rev"] as? NSNumber)?.int64Value ?? 0)
        if !note.hasImage, local != nil {
            try db.clearImage(id: id)
            try? FileManager.default.removeItem(at: AppPaths.noteImageURL(id))
        }
    }

    private func applyFolder(_ item: [String: Any], force: Bool) throws {
        guard let id = item["id"] as? String else { return }
        if !force, try db.folderIsDirty(id) { return }
        if item["deleted"] as? Bool == true {
            try db.removeFolder(id: id)
            return
        }
        try db.saveFolder(Database.FolderRow(id: id, name: item["name"] as? String ?? "", color: item["color"] as? String,
                                             createdAt: (item["createdAt"] as? NSNumber)?.doubleValue ?? 0,
                                             updatedAt: (item["updatedAt"] as? NSNumber)?.doubleValue ?? 0, deleted: false),
                          dirty: false)
    }

    private func applyTag(_ item: [String: Any], force: Bool) throws {
        guard let name = item["name"] as? String else { return }
        if !force, try db.tagIsDirty(name) { return }
        let color = item["deleted"] as? Bool == true ? nil : item["color"] as? String
        try db.saveTag(Database.TagRow(name: name, color: color, updatedAt: (item["updatedAt"] as? NSNumber)?.doubleValue ?? 0),
                       dirty: false)
    }

    /// Fetches the pictures this device doesn't have yet, newest notes first, so every note is there offline.
    func downloadImages() async {
        guard !downloading, ServerConfig.serverURL != nil else { return }
        downloading = true
        defer { downloading = false }
        guard let missing = try? db.missingImages(), !missing.isEmpty else { return }
        var fetched = 0
        for (id, sha) in missing {
            do {
                if let data = try await client.downloadImage(noteID: id) {
                    try data.write(to: AppPaths.noteImageURL(id), options: .atomic)
                    try db.setImageDownloaded(id: id, sha: sha)
                } else {
                    try db.clearImage(id: id)
                }
                fetched += 1
                if fetched % 10 == 0 { reloadNotes() }
            } catch {
                IonotesClient.log.error("picture of \(id, privacy: .public) not fetched: \(error.localizedDescription, privacy: .public)")
                break  // offline or signed out: the next sync tries again
            }
        }
        reloadNotes()
    }

    // MARK: - Server and account

    /// Saves the server address. A different server starts afresh: what came from the old one is dropped,
    /// changes not sent yet are kept for the new one.
    func setServer(_ url: URL?) {
        let old = ServerConfig.serverURL
        guard url?.absoluteString != old?.absoluteString else { return }
        if old != nil {
            client.forgetCookies(for: old)
            do {
                for id in try db.forgetSynced() {
                    try? FileManager.default.removeItem(at: AppPaths.noteImageURL(id))
                }
            } catch {
                report(error)
            }
        }
        ServerConfig.serverURL = url
        account = nil
        lastSync = nil
        syncStatus = url == nil ? .notConfigured : .syncing
        reloadNotes()
        if url != nil { Task { await refreshAccount() } }
    }

    /// Who this device is signed in as; syncs once signed in.
    func refreshAccount() async {
        guard ServerConfig.serverURL != nil else {
            account = nil
            syncStatus = .notConfigured
            return
        }
        do {
            let me = try await client.account()
            account = me.signedIn ? me : nil
            if me.signedIn { await sync() } else { syncStatus = .signedOut }
        } catch IonotesError.needsSignIn {
            account = nil
            syncStatus = .signedOut
        } catch let error as URLError {
            syncStatus = .offline(error.localizedDescription)
        } catch {
            syncStatus = .failed(error.localizedDescription)
        }
    }

    func signIn(name: String, password: String) async throws {
        try await client.signIn(name: name, password: password)
        await refreshAccount()
    }

    func signOut() async {
        await client.signOut()
        await CookieSync.clearWebView()
        account = nil
        syncStatus = .signedOut
    }

    func setServiceToken(id: String?, secret: String?) {
        let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        let both = !(id ?? "").isEmpty && !(secret ?? "").isEmpty
        ServiceToken.clientID = both ? id : nil
        ServiceToken.clientSecret = both ? secret : nil
        client.reloadToken()
        Task { await refreshAccount() }
    }

    /// One line for the sidebar and Settings.
    var syncSummary: String {
        switch syncStatus {
        case .notConfigured: return "Not connected to a server"
        case .signedOut: return "Signed out of the server"
        case .syncing: return "Syncing…"
        case .synced:
            if pendingChanges > 0 { return "\(pendingChanges) change\(pendingChanges == 1 ? "" : "s") to send" }
            return lastSync.map { "Synced \($0.formatted(date: .omitted, time: .shortened))" } ?? "Synced"
        case .offline: return pendingChanges > 0 ? "Offline, \(pendingChanges) change\(pendingChanges == 1 ? "" : "s") to send" : "Offline"
        case .failed: return "Sync problem"
        }
    }

    var syncProblem: String? {
        switch syncStatus {
        case .offline(let why), .failed(let why): return why
        case .signedOut: return IonotesError.needsSignIn.errorDescription
        case .notConfigured: return IonotesError.noServer.errorDescription
        default: return nil
        }
    }
}
