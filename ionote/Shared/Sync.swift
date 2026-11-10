import Foundation
import Network

/// Syncing with the ionotes server. Changes made here are saved locally first and marked dirty; a sync sends
/// them (POST /api/sync/push), uploads new pictures, then fetches everything changed on the server since the
/// last rev (GET /api/sync), and finally fetches pictures this device doesn't have yet. It runs on launch, when
/// the app comes to the front, shortly after an edit, every minute while active, and when the network returns.
/// An edit made here and not sent yet always wins over the server's copy until the server has seen it; the
/// server then decides by edit time ("stale": its copy is newer and is kept, and the text written here is kept
/// beside it as a note of its own). Changes go up in batches the server takes in one request; one the server
/// refuses ("error") stays on this device and is sent again only once it is edited.
extension NotesStore {
    private static let pollInterval: TimeInterval = 60
    /// One push carries at most this much note text and this many notes: the server refuses a body over 8 MiB.
    private static let pushBytes = 2_000_000
    private static let pushNotes = 200

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

        // the notes in batches the server takes; the folders and tag colours go with the first (a note names its folder)
        var batches: [[(note: Note, deleted: Bool)]] = [[]]
        var size = 0
        for item in notes {
            let n = item.note
            let bytes = item.deleted ? 200 : n.title.utf8.count + n.body.utf8.count + n.ocrText.utf8.count + 600
            if !batches[batches.count - 1].isEmpty, size + bytes > Self.pushBytes || batches[batches.count - 1].count >= Self.pushNotes {
                batches.append([])
                size = 0
            }
            batches[batches.count - 1].append(item)
            size += bytes
        }
        var refused: [String] = []
        var copies = 0
        for (i, batch) in batches.enumerated() {
            let result = try await push(notes: batch, folders: i == 0 ? folders : [], tags: i == 0 ? tags : [])
            refused += result.refused
            copies += result.copies
        }
        reloadNotes()
        if copies > 0 {
            syncAgain = true  // the copies kept of what was written here go to the server too
        }
        if !refused.isEmpty {
            let what = refused.count == 1 ? "a change" : "\(refused.count) changes"
            lastError = "The server refused \(what): \(refused[0]). What it refused stays on this device and is sent again once it is edited."
        }
    }

    /// One push request and what the server said about each item: the reasons of what it refused, and how many
    /// notes written here were kept as copies. A request the server finds too large is sent again in two halves;
    /// a single note that is too large by itself is refused like any other.
    private func push(notes: [(note: Note, deleted: Bool)], folders: [Database.FolderRow], tags: [Database.TagRow]) async throws -> (refused: [String], copies: Int) {
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
        let answer: [String: Any]
        do {
            answer = try await client.push(notes: noteDicts, folders: folderDicts, tags: tagDicts)
        } catch IonotesError.tooLarge {
            if notes.count > 1 {
                let half = notes.count / 2
                let first = try await push(notes: Array(notes[..<half]), folders: folders, tags: tags)
                let second = try await push(notes: Array(notes[half...]), folders: [], tags: [])
                return (first.refused + second.refused, first.copies + second.copies)
            }
            guard let only = notes.first else { throw IonotesError.tooLarge }  // the folders and colours alone: nothing to split
            try db.markRefused(note: only.note.id, updatedAt: only.note.updatedAt.timeIntervalSince1970)
            IonotesClient.log.error("note \(only.note.id, privacy: .public) is larger than the server takes")
            var rest: (refused: [String], copies: Int) = ([], 0)
            if !folders.isEmpty || !tags.isEmpty {
                rest = try await push(notes: [], folders: folders, tags: tags)
            }
            return (["\u{201C}\(only.note.displayTitle)\u{201D} is larger than the server takes"] + rest.refused, rest.copies)
        }
        let rev = (answer["rev"] as? NSNumber)?.int64Value ?? 0
        var refused: [String] = []
        var copies = 0

        try db.transaction {
            for (sent, result) in zip(folders, answer["folders"] as? [[String: Any]] ?? []) {
                switch result["status"] as? String {
                case "ok":
                    try db.markFolderSent(id: sent.id, updatedAt: sent.updatedAt)
                case "stale":
                    if let item = result["item"] as? [String: Any] { try applyFolder(item, force: true) }
                default:
                    let why = result["error"] as? String ?? "no reason given"
                    IonotesClient.log.error("folder \(sent.id, privacy: .public) refused: \(why, privacy: .public)")
                    try db.markFolderRefused(id: sent.id, updatedAt: sent.updatedAt)
                    refused.append("the folder \u{201C}\(sent.name)\u{201D}, \(why)")
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
                        if let files = Self.attachments(of: item, noteID: id) { try db.setAttachments(noteID: id, files) }
                    }
                case "stale":
                    if let item = result["item"] as? [String: Any] {
                        if try keepCopy(ofNote: id, replacedBy: item) { copies += 1 }
                        try applyNote(item, force: true)
                    }
                default:
                    let why = result["error"] as? String ?? "no reason given"
                    IonotesClient.log.error("note \(id, privacy: .public) refused: \(why, privacy: .public)")
                    try db.markRefused(note: id, updatedAt: sentAt)
                    refused.append("\u{201C}\(sent.note.displayTitle)\u{201D}, \(why)")
                }
            }
            for (sent, result) in zip(tags, answer["tags"] as? [[String: Any]] ?? []) {
                switch result["status"] as? String {
                case "ok":
                    try db.markTagSent(name: sent.name, updatedAt: sent.updatedAt)
                case "stale":
                    if let item = result["item"] as? [String: Any] { try applyTag(item, force: true) }
                default:
                    let why = result["error"] as? String ?? "no reason given"
                    try db.markTagRefused(name: sent.name, updatedAt: sent.updatedAt)
                    refused.append("the colour of the tag \(sent.name), \(why)")
                }
            }
        }
        return (refused, copies)
    }

    /// The server kept its own, later copy of a note that was changed here as well ("stale"): before that copy
    /// replaces the note, the text written here is saved as a note of its own, so nothing typed on this device is
    /// lost. Not when the note was deleted here, when the text is the same (only tags, the folder or the pin
    /// differ), or when there is no text. Answers whether a copy was made.
    private func keepCopy(ofNote id: String, replacedBy item: [String: Any]) throws -> Bool {
        guard let mine = try db.note(id: id) else { return false }
        let gone = item["deleted"] as? Bool == true
        if !gone, mine.title == item["title"] as? String ?? "", mine.body == item["body"] as? String ?? "" { return false }
        let blank = CharacterSet.whitespacesAndNewlines
        if mine.title.trimmingCharacters(in: blank).isEmpty, mine.body.trimmingCharacters(in: blank).isEmpty { return false }
        var copy = mine
        copy.id = UUID().uuidString
        copy.title = "\(mine.displayTitle) (copy of an edit made here)"
        copy.hasImage = false  // the picture stays with the note itself
        copy.imageKey = nil
        copy.ocrText = ""
        copy.pinned = false
        copy.updatedAt = Date()
        try db.saveLocal(copy)
        return true
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
        // once, after the update that brought attached files and templates: everything again, so notes synced
        // before then get their lists of files (changes made here and not sent yet are kept as always)
        let fullOnce = try db.meta("fetched-v2") != "1"
        if fullOnce { since = 0 }
        while true {
            let page = try await client.changes(since: since)
            try db.transaction {
                for item in page["folders"] as? [[String: Any]] ?? [] { try applyFolder(item, force: false) }
                for item in page["notes"] as? [[String: Any]] ?? [] { try applyNote(item, force: false) }
                for item in page["tags"] as? [[String: Any]] ?? [] { try applyTag(item, force: false) }
                for item in page["templates"] as? [[String: Any]] ?? [] { try applyTemplate(item) }
                since = (page["rev"] as? NSNumber)?.int64Value ?? since
                try db.setMeta("rev", String(since))
            }
            guard page["more"] as? Bool == true else { break }
        }
        if fullOnce { try db.setMeta("fetched-v2", "1") }
        reloadNotes()
    }

    private func applyTemplate(_ item: [String: Any]) throws {
        guard let id = item["id"] as? String else { return }
        if item["deleted"] as? Bool == true {
            try db.removeTemplate(id: id)
            return
        }
        try db.saveTemplate(NoteTemplate(id: id, name: item["name"] as? String ?? "", title: item["title"] as? String ?? "",
                                         body: item["body"] as? String ?? "", tags: item["tags"] as? [String] ?? [],
                                         folderID: item["folderID"] as? String),
                            updatedAt: (item["updatedAt"] as? NSNumber)?.doubleValue ?? 0)
    }

    /// The server's list of a note's attached files, as it comes with the note.
    static func attachments(of item: [String: Any], noteID: String) -> [Attachment]? {
        guard let list = item["attachments"] as? [[String: Any]] else { return nil }
        return list.compactMap { a in
            guard let id = a["id"] as? String else { return nil }
            return Attachment(id: id, noteID: noteID, name: a["name"] as? String ?? "file", mime: a["mime"] as? String ?? "",
                              bytes: (a["bytes"] as? NSNumber)?.intValue ?? 0, sha: a["sha"] as? String,
                              width: (a["width"] as? NSNumber)?.intValue, height: (a["height"] as? NSNumber)?.intValue,
                              createdAt: (a["createdAt"] as? NSNumber)?.doubleValue ?? 0)
        }
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
            try db.setAttachments(noteID: id, [])
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
        if let files = Self.attachments(of: item, noteID: id) { try db.setAttachments(noteID: id, files) }
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
