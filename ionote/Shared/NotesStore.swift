import CloudKit
import CoreData
import CryptoKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    /// A note being dragged inside ionotes (onto a folder); declared in Info.plist.
    static let ionotesNote = UTType(exportedAs: "net.iothing.ionotes.note")
}

enum Prefs {
    static let clipboardEnabled = "clipboardEnabled"
    static let screenshotsEnabled = "screenshotsEnabled"
    static let autoSaveScreenshots = "autoSaveScreenshots"
    static let inboxLimit = "inboxLimit"
    /// "system", "light" or "dark".
    static let appearance = "appearance"
    /// Skip copied text that looks like a password (for password managers in a browser).
    static let skipPasswordLikeText = "skipPasswordLikeText"
    /// Bundle ids of apps whose copies never go into the Inbox (password managers).
    static let ignoredApps = "ignoredApps"

    /// Password managers that don't all mark what they copy as private, so copies made while they are
    /// in front are skipped. Editable in Settings.
    static let defaultIgnoredApps = [
        "me.proton.pass.electron",          // Proton Pass
        "com.1password.1password",          // 1Password 8
        "com.agilebits.onepassword7",       // 1Password 7
        "com.bitwarden.desktop",            // Bitwarden
        "org.keepassxc.keepassxc",          // KeePassXC
        "com.apple.Passwords",              // Passwords
        "com.apple.keychainaccess",         // Keychain Access
        "com.dashlane.dashlanephonefinal",  // Dashlane
        "com.lastpass.LastPass",            // LastPass
        "in.sinew.Enpass-Desktop",          // Enpass
    ]

    static func register() {
        UserDefaults.standard.register(defaults: [
            clipboardEnabled: true,
            screenshotsEnabled: true,
            autoSaveScreenshots: false,
            inboxLimit: 500,
            appearance: "system",
            ignoredApps: defaultIgnoredApps,
            skipPasswordLikeText: true,
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    static var ignoredAppIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: ignoredApps) ?? defaultIgnoredApps }
        set { UserDefaults.standard.set(newValue, forKey: ignoredApps) }
    }
}

/// How the notes list is ordered (pinned notes always come first).
enum NoteSort: String, CaseIterable, Identifiable {
    case newest, oldest, edited, title
    var id: Self { self }
    var label: String {
        switch self {
        case .newest: return "Newest First"
        case .oldest: return "Oldest First"
        case .edited: return "Recently Edited"
        case .title: return "Title"
        }
    }
}

struct TagCount: Identifiable, Hashable {
    let name: String
    let count: Int
    var id: String { name }
}

/// The app's single source of truth. Notes live in SwiftData (synced through iCloud) and are
/// mirrored into a local SQLite full-text index for search. The clipboard inbox is local only.
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    enum SyncState: Equatable {
        case checking, syncing, localOnly, noAccount(String)
    }

    @Published private(set) var notes: [Note] = []
    @Published private(set) var inbox: [InboxItem] = []
    @Published private(set) var ocrInProgress: Set<String> = []
    @Published private(set) var syncState: SyncState = .checking
    @Published var lastError: String?
    @Published private(set) var tags: [TagCount] = []
    @Published private(set) var folders: [Folder] = []
    /// Lowercased tag name -> colour.
    @Published private(set) var tagColors: [String: LabelColor] = [:]
    /// Show only notes filed in this folder (picked in the sidebar). New notes go there too.
    @Published var selectedFolder: String? {
        didSet { reloadNotes() }
    }
    @Published private(set) var totalNotes = 0
    @Published var searchText = "" {
        didSet { reloadNotes() }
    }
    /// Show only notes with this tag (picked in the sidebar).
    @Published var selectedTag: String? {
        didSet { reloadNotes() }
    }
    @Published var sort = NoteSort(rawValue: UserDefaults.standard.string(forKey: "noteSort") ?? "") ?? .newest {
        didSet {
            UserDefaults.standard.set(sort.rawValue, forKey: "noteSort")
            reloadNotes()
        }
    }

    /// The pasteboard change count of our own last write, so the Mac clipboard monitor can skip it.
    var ownPasteboardChange: Int?

    let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private let db: Database
    private var observers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?

    private init() {
        Prefs.register()
        do {
            db = try Database(url: AppPaths.databaseURL)
        } catch {
            fatalError("ionotes could not open its database: \(error)")
        }
        container = Persistence.makeContainer(syncWithICloud: true)
        reindex()
        reloadInbox()

        // Notes arriving from other devices: re-index when the store reports remote changes,
        // and every minute as a fallback.
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reindex() }
        })
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reindex() }
        }
        Task { await checkICloud() }
    }

    var filteredInbox: [InboxItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return inbox }
        return inbox.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    func note(id: String?) -> Note? {
        guard let id else { return nil }
        return notes.first { $0.id == id }
    }

    // MARK: - iCloud

    func checkICloud() async {
        guard Entitlements.hasCloudKit, let id = Persistence.cloudKitContainerID else {
            syncState = .localOnly
            return
        }
        do {
            switch try await CKContainer(identifier: id).accountStatus() {
            case .available: syncState = .syncing
            case .noAccount: syncState = .noAccount("Sign in to iCloud in Settings to sync your notes.")
            case .restricted: syncState = .noAccount("iCloud is restricted on this device.")
            case .temporarilyUnavailable: syncState = .noAccount("iCloud is temporarily unavailable.")
            default: syncState = .noAccount("Could not reach iCloud.")
            }
        } catch {
            syncState = .noAccount(error.localizedDescription)
        }
    }

    // MARK: - Search index

    /// Brings the search index in line with SwiftData: picks up notes created or edited on
    /// other devices and drops notes deleted elsewhere.
    func reindex() {
        do {
            let records = try context.fetch(FetchDescriptor<NoteRecord>())
            let indexed = try db.indexedVersions()
            var present = Set<String>()
            for record in records where present.insert(record.uuid).inserted {
                let version = record.updatedAt.timeIntervalSince1970
                if indexed[record.uuid] != version {
                    try db.upsert(record.snapshot, version: version)
                }
            }
            for id in indexed.keys where !present.contains(id) {
                try db.deleteNote(id: id)
            }
        } catch {
            report(error)
        }
        reloadNotes()
    }

    private func reloadNotes() {
        do {
            var list = try db.notes(matching: searchText)
            if let folder = selectedFolder {
                list = list.filter { $0.folderID == folder }
            }
            if let tag = selectedTag {
                list = list.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
            }
            // A search keeps its best-match order; otherwise the chosen sort applies.
            if Database.ftsQuery(from: searchText) == nil {
                list.sort(by: sortComparator)
            }
            notes = list.filter(\.pinned) + list.filter { !$0.pinned }
            tags = try db.allTags().map { TagCount(name: $0.name, count: $0.count) }
            totalNotes = try db.indexedVersions().count
            let counts = try db.folderCounts()
            let records = (try? context.fetch(FetchDescriptor<FolderRecord>())) ?? []
            folders = records
                .map { Folder(id: $0.uuid, name: $0.name, count: counts[$0.uuid] ?? 0,
                              color: $0.color.flatMap(LabelColor.init(rawValue:))) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            var colors: [String: LabelColor] = [:]
            for record in (try? context.fetch(FetchDescriptor<TagRecord>())) ?? [] {
                if let color = record.color.flatMap(LabelColor.init(rawValue:)) { colors[record.name.lowercased()] = color }
            }
            tagColors = colors
        } catch {
            report(error)
        }
    }

    private var sortComparator: (Note, Note) -> Bool {
        switch sort {
        case .newest: return { $0.createdAt > $1.createdAt }
        case .oldest: return { $0.createdAt < $1.createdAt }
        case .edited: return { $0.updatedAt > $1.updatedAt }
        case .title: return { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        }
    }

    private func reloadInbox() {
        do {
            inbox = try db.inboxItems()
        } catch {
            report(error)
        }
    }

    // MARK: - Notes

    private func fetchRecord(id: String) -> NoteRecord? {
        let descriptor = FetchDescriptor<NoteRecord>(predicate: #Predicate<NoteRecord> { $0.uuid == id })
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    func createTextNote(_ text: String, source: String, sourceApp: String? = nil) -> Note? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let record = NoteRecord(title: Note.firstLine(of: trimmed) ?? "", body: trimmed, source: source, sourceApp: sourceApp)
        return insert(record)
    }

    @discardableResult
    func createImageNote(data: Data, title: String? = nil, source: String, sourceApp: String? = nil) -> Note? {
        let record = NoteRecord(imageData: data, source: source, sourceApp: sourceApp)
        record.title = title ?? NotesStore.defaultImageTitle(source: source, date: record.createdAt)
        guard let note = insert(record) else { return nil }
        runOCR(on: note)
        return note
    }

    func createBlankNote() -> Note? {
        let record = NoteRecord(title: "New note", source: "manual")
        record.folderID = selectedFolder  // a new note goes into the folder you're looking at
        return insert(record)
    }

    func updateNote(id: String, title: String, body: String) {
        guard let record = fetchRecord(id: id), record.title != title || record.body != body else { return }
        record.title = title
        record.body = body
        record.updatedAt = Date()
        commit()
    }

    func setTags(_ tags: [String], for id: String) {
        guard let record = fetchRecord(id: id) else { return }
        let clean = Note.cleanTags(tags)
        guard clean != record.tags else { return }
        record.tags = clean
        record.updatedAt = Date()
        commit()
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(named name: String) -> Folder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = folders.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        let record = FolderRecord(name: trimmed)
        context.insert(record)
        commit()
        return Folder(id: record.uuid, name: trimmed, count: 0)
    }

    func renameFolder(_ folder: Folder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let record = fetchFolder(id: folder.id) else { return }
        record.name = trimmed
        commit()
    }

    /// Deletes the folder; its notes stay, just no longer filed anywhere.
    func deleteFolder(_ folder: Folder) {
        let id = folder.id
        let match: String? = id
        let filed = (try? context.fetch(FetchDescriptor<NoteRecord>(predicate: #Predicate<NoteRecord> { $0.folderID == match }))) ?? []
        for record in filed {
            record.folderID = nil
            record.updatedAt = Date()
        }
        if let record = fetchFolder(id: id) { context.delete(record) }
        if selectedFolder == id { selectedFolder = nil }
        commit()
    }

    func setColor(_ color: LabelColor?, forFolder folder: Folder) {
        guard let record = fetchFolder(id: folder.id) else { return }
        record.color = color?.rawValue
        commit()
    }

    func tagColor(_ name: String) -> LabelColor? {
        tagColors[name.lowercased()]
    }

    func setColor(_ color: LabelColor?, forTag name: String) {
        let key = name.lowercased()
        let records = ((try? context.fetch(FetchDescriptor<TagRecord>())) ?? []).filter { $0.name.lowercased() == key }
        if let first = records.first {
            first.color = color?.rawValue
            records.dropFirst().forEach { context.delete($0) }  // the same tag coloured on two devices
        } else if color != nil {
            context.insert(TagRecord(name: name, color: color?.rawValue))
        }
        commit()
    }

    func moveNote(id: String, toFolder folderID: String?) {
        guard let record = fetchRecord(id: id), record.folderID != folderID else { return }
        record.folderID = folderID
        record.updatedAt = Date()
        commit()
    }

    func folderName(_ id: String?) -> String? {
        guard let id else { return nil }
        return folders.first { $0.id == id }?.name
    }

    private func fetchFolder(id: String) -> FolderRecord? {
        try? context.fetch(FetchDescriptor<FolderRecord>(predicate: #Predicate<FolderRecord> { $0.uuid == id })).first
    }

    func togglePin(_ note: Note) {
        guard let record = fetchRecord(id: note.id) else { return }
        record.pinned.toggle()
        record.updatedAt = Date()
        commit()
    }

    func deleteNote(_ note: Note) {
        if let record = fetchRecord(id: note.id) {
            context.delete(record)
            commit()
        }
        try? db.clearInboxLinks(toNote: note.id)
        reloadInbox()
    }

    func imageData(for note: Note) -> Data? {
        guard note.hasImage else { return nil }
        return fetchRecord(id: note.id)?.imageData
    }

    /// Recognizes text in the note's image in the background and stores it so the note is searchable.
    func runOCR(on note: Note) {
        guard let data = imageData(for: note), !ocrInProgress.contains(note.id) else { return }
        ocrInProgress.insert(note.id)
        let id = note.id
        Task {
            let text = await OCR.recognizeText(in: data)
            ocrInProgress.remove(id)
            guard let record = fetchRecord(id: id) else { return }
            record.ocrText = text
            record.updatedAt = Date()
            commit()
        }
    }

    private func insert(_ record: NoteRecord) -> Note? {
        context.insert(record)
        commit()
        return record.snapshot
    }

    private func commit() {
        do {
            try context.save()
        } catch {
            report(error)
        }
        reindex()
    }

    private static func defaultImageTitle(source: String, date: Date) -> String {
        let stamp = date.formatted(date: .abbreviated, time: .shortened)
        switch source {
        case "screenshot": return "Screenshot \(stamp)"
        case "photo": return "Photo \(stamp)"
        default: return "Image \(stamp)"
        }
    }

    // MARK: - Inbox

    func addInboxText(_ text: String, sourceApp: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        addInbox(kind: .text, text: text, imagePath: nil, source: "clipboard", sourceApp: sourceApp,
                 hash: NotesStore.hash(Data(("text:" + text).utf8)))
    }

    /// Adds image data (PNG) to the inbox. Files are named by content hash, so the same image is stored once.
    func addInboxImage(png: Data, label: String, source: String, sourceApp: String?) {
        let hash = NotesStore.hash(png)
        let url = AppPaths.inboxImagesDir.appendingPathComponent(String(hash.prefix(32)) + ".png")
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try png.write(to: url, options: .atomic)
            }
            addInbox(kind: .image, text: label, imagePath: url.path, source: source, sourceApp: sourceApp, hash: hash)
        } catch {
            report(error)
        }
    }

    /// A new screenshot file appeared: save it straight to notes, or queue it in the inbox.
    func addScreenshot(at url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        if Prefs.bool(Prefs.autoSaveScreenshots) {
            createImageNote(data: data, source: "screenshot")
        } else {
            let label = url.deletingPathExtension().lastPathComponent
            let png = ImageCoding.png(from: data)
            addInboxImage(png: png, label: label, source: "screenshot", sourceApp: nil)
        }
    }

    private func addInbox(kind: InboxItem.Kind, text: String, imagePath: String?, source: String, sourceApp: String?, hash: String) {
        do {
            try db.addInboxItem(kind: kind, text: text, imagePath: imagePath, source: source, sourceApp: sourceApp, hash: hash)
            let limit = max(UserDefaults.standard.integer(forKey: Prefs.inboxLimit), 10)
            for path in try db.trimInbox(keep: limit) {
                try? FileManager.default.removeItem(atPath: path)
            }
        } catch {
            report(error)
        }
        reloadInbox()
    }

    /// Saves an inbox item as a note and takes it out of the Inbox.
    @discardableResult
    func saveAsNote(_ item: InboxItem, inFolder folderID: String? = nil) -> Note? {
        if let id = item.noteId, let existing = note(id: id) ?? fetchRecord(id: id)?.snapshot {
            deleteInboxItem(item)  // saved before items left the Inbox on saving
            return existing
        }
        let saved: Note?
        switch item.kind {
        case .text:
            saved = createTextNote(item.text, source: item.source, sourceApp: item.sourceApp)
        case .image:
            guard let url = item.imageURL, let data = try? Data(contentsOf: url) else { return nil }
            let title: String? = (item.source == "screenshot" || item.text.isEmpty) ? nil : item.text
            saved = createImageNote(data: data, title: title, source: item.source, sourceApp: item.sourceApp)
        }
        if let saved, let folderID {
            moveNote(id: saved.id, toFolder: folderID)
        }
        // Once it is a note it leaves the Inbox (the note keeps its own copy of any image).
        if saved != nil {
            deleteInboxItem(item)
        }
        return saved
    }

    func deleteInboxItem(_ item: InboxItem) {
        if let path = item.imagePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        try? db.deleteInboxItem(item.id)
        reloadInbox()
    }

    func clearInbox() {
        for path in (try? db.allInboxImagePaths()) ?? [] {
            try? FileManager.default.removeItem(atPath: path)
        }
        try? db.clearInbox()
        reloadInbox()
    }

    // MARK: - Image files

    /// A PNG of the note's picture with a readable name, for saving, opening and sharing.
    /// The file is written once per note and reused, so this is quick after the first time.
    func imageFileURL(for note: Note) -> URL? {
        imageData(for: note).flatMap { exportFile($0, name: note.displayTitle, key: note.id) }
    }

    func imageFileURL(for item: InboxItem) -> URL? {
        guard item.kind == .image, let source = item.imageURL, let data = try? Data(contentsOf: source) else { return nil }
        return exportFile(data, name: item.text.isEmpty ? "Image" : item.text, key: Self.exportKey(item))
    }

    /// The same file as `imageFileURL(for:)`, but encoded and written off the main thread.
    func preparedImageFileURL(for note: Note) async -> URL? {
        guard let data = imageData(for: note) else { return nil }
        let name = note.displayTitle, key = note.id
        return await Task.detached(priority: .utility) { ImageExport.write(data, name: name, key: key) }.value
    }

    func preparedImageFileURL(for item: InboxItem) async -> URL? {
        guard item.kind == .image, let source = item.imageURL else { return nil }
        let name = item.text.isEmpty ? "Image" : item.text, key = Self.exportKey(item)
        return await Task.detached(priority: .utility) {
            (try? Data(contentsOf: source)).flatMap { ImageExport.write($0, name: name, key: key) }
        }.value
    }

    /// Writes image data to a temporary file with a readable name ("Screenshot 28 Oct 2026 at 20.21.png").
    /// With a key, the file is kept and reused for that picture.
    func exportFile(_ data: Data, name: String, key: String? = nil) -> URL? {
        ImageExport.write(data, name: name, key: key)
    }

    private static func exportKey(_ item: InboxItem) -> String {
        "inbox-" + (item.imageURL?.deletingPathExtension().lastPathComponent ?? "\(item.id)")
    }

    // MARK: - Helpers

    func report(_ error: Error) {
        NSLog("ionotes error: \(error)")
        lastError = "\(error)"
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
