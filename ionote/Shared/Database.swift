import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DatabaseError: Error, CustomStringConvertible {
    let description: String
}

/// Local SQLite database: the full offline copy of the notes, folders and tag colours (with what still has to go
/// to the server), a full-text index (FTS5) of the notes, and the clipboard inbox (this device only).
/// Used from the main thread only.
final class Database {
    private var db: OpaquePointer?

    init(url: URL) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw DatabaseError(description: "Could not open database at \(url.path)")
        }
        try migrate()
        try exec(Database.schema)
    }

    /// Version 2 and older only held a search index of the iCloud notes, so moving on simply drops it: the
    /// notes come from the server now.
    private static let notesVersion: Int32 = 3

    private func migrate() throws {
        var version: Int32 = 0
        try query("PRAGMA user_version", []) { version = sqlite3_column_int($0, 0) }
        guard version < Database.notesVersion else { return }
        try exec("""
            DROP TRIGGER IF EXISTS notes_ai; DROP TRIGGER IF EXISTS notes_ad; DROP TRIGGER IF EXISTS notes_au;
            DROP TABLE IF EXISTS notes_fts; DROP TABLE IF EXISTS notes;
            PRAGMA user_version = \(Database.notesVersion);
            """)
    }

    deinit { sqlite3_close(db) }

    // dirty: changed here and not yet taken by the server. deleted: deleted here, waiting to be sent.
    // image_sha: the server's picture; image_local: which picture the file on this device is (a sha, or
    // "local" for one made here); image_pending: the file still has to be uploaded.
    private static let schema = """
    PRAGMA journal_mode = WAL;

    CREATE TABLE IF NOT EXISTS notes (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        body TEXT NOT NULL DEFAULT '',
        ocr_text TEXT NOT NULL DEFAULT '',
        has_image INTEGER NOT NULL DEFAULT 0,
        source TEXT NOT NULL DEFAULT 'manual',
        source_app TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        tags TEXT NOT NULL DEFAULT '',
        pinned INTEGER NOT NULL DEFAULT 0,
        folder_id TEXT,
        image_sha TEXT,
        image_local TEXT,
        image_pending INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        rev INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS notes_dirty ON notes(dirty);

    CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
        title, body, ocr_text, tags,
        content = 'notes', content_rowid = 'rowid',
        tokenize = 'porter unicode61 remove_diacritics 2'
    );

    CREATE TRIGGER IF NOT EXISTS notes_ai AFTER INSERT ON notes BEGIN
        INSERT INTO notes_fts(rowid, title, body, ocr_text, tags) VALUES (new.rowid, new.title, new.body, new.ocr_text, new.tags);
    END;
    CREATE TRIGGER IF NOT EXISTS notes_ad AFTER DELETE ON notes BEGIN
        INSERT INTO notes_fts(notes_fts, rowid, title, body, ocr_text, tags) VALUES ('delete', old.rowid, old.title, old.body, old.ocr_text, old.tags);
    END;
    CREATE TRIGGER IF NOT EXISTS notes_au AFTER UPDATE OF title, body, ocr_text, tags ON notes BEGIN
        INSERT INTO notes_fts(notes_fts, rowid, title, body, ocr_text, tags) VALUES ('delete', old.rowid, old.title, old.body, old.ocr_text, old.tags);
        INSERT INTO notes_fts(rowid, title, body, ocr_text, tags) VALUES (new.rowid, new.title, new.body, new.ocr_text, new.tags);
    END;

    CREATE TABLE IF NOT EXISTS folders (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL DEFAULT '',
        color TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        dirty INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS tag_colors (
        key TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        color TEXT,
        updated_at REAL NOT NULL,
        dirty INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT
    );

    CREATE TABLE IF NOT EXISTS inbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        text TEXT NOT NULL DEFAULT '',
        image_path TEXT,
        source TEXT NOT NULL,
        source_app TEXT,
        hash TEXT NOT NULL,
        created_at REAL NOT NULL,
        note_id TEXT
    );
    CREATE INDEX IF NOT EXISTS inbox_created ON inbox(created_at DESC);
    CREATE INDEX IF NOT EXISTS inbox_hash ON inbox(hash);
    """

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Notes

    private static let noteColumns = "n.id, n.title, n.body, n.ocr_text, n.has_image, n.source, n.source_app, n.created_at, n.updated_at, n.tags, n.pinned, n.folder_id, n.image_local"

    private static func readNote(_ stmt: OpaquePointer) -> Note {
        Note(id: string(stmt, 0),
             title: string(stmt, 1),
             body: string(stmt, 2),
             ocrText: string(stmt, 3),
             hasImage: sqlite3_column_int(stmt, 4) != 0,
             source: string(stmt, 5),
             sourceApp: optionalString(stmt, 6),
             createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
             updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
             tags: string(stmt, 9).split(separator: "\n").map(String.init),
             pinned: sqlite3_column_int(stmt, 10) != 0,
             folderID: optionalString(stmt, 11),
             imageKey: optionalString(stmt, 12))
    }

    /// Saves a note made or changed on this device, marked to be sent to the server.
    func saveLocal(_ note: Note) throws {
        try run("""
            INSERT INTO notes (id, title, body, ocr_text, has_image, source, source_app, created_at, updated_at, tags, pinned, folder_id, dirty)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title, body = excluded.body, ocr_text = excluded.ocr_text, has_image = excluded.has_image,
                source = excluded.source, source_app = excluded.source_app, created_at = excluded.created_at,
                updated_at = excluded.updated_at, tags = excluded.tags, pinned = excluded.pinned,
                folder_id = excluded.folder_id, dirty = 1
            """,
            [note.id, note.title, note.body, note.ocrText, note.hasImage ? 1 : 0, note.source, note.sourceApp,
             note.createdAt.timeIntervalSince1970, note.updatedAt.timeIntervalSince1970,
             note.tags.joined(separator: "\n"), note.pinned ? 1 : 0, note.folderID])
    }

    /// Takes the server's copy of a note (it is not changed here, or the server's edit is newer).
    func saveFromServer(_ note: Note, imageSHA: String?, rev: Int64) throws {
        try run("""
            INSERT INTO notes (id, title, body, ocr_text, has_image, source, source_app, created_at, updated_at, tags, pinned, folder_id, image_sha, rev, dirty, deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title, body = excluded.body, ocr_text = excluded.ocr_text, has_image = excluded.has_image,
                source = excluded.source, source_app = excluded.source_app, created_at = excluded.created_at,
                updated_at = excluded.updated_at, tags = excluded.tags, pinned = excluded.pinned,
                folder_id = excluded.folder_id, image_sha = excluded.image_sha, rev = excluded.rev, dirty = 0, deleted = 0
            """,
            [note.id, note.title, note.body, note.ocrText, note.hasImage ? 1 : 0, note.source, note.sourceApp,
             note.createdAt.timeIntervalSince1970, note.updatedAt.timeIntervalSince1970,
             note.tags.joined(separator: "\n"), note.pinned ? 1 : 0, note.folderID, imageSHA, rev])
    }

    func note(id: String) throws -> Note? {
        var found: Note?
        try query("SELECT \(Database.noteColumns) FROM notes n WHERE n.id = ? AND n.deleted = 0", [id]) { found = Database.readNote($0) }
        return found
    }

    /// The sync state of a note on this device, or nil when it isn't here.
    func syncState(ofNote id: String) throws -> (dirty: Bool, deleted: Bool, updatedAt: Double, imagePending: Bool, rev: Int64)? {
        var found: (Bool, Bool, Double, Bool, Int64)?
        try query("SELECT dirty, deleted, updated_at, image_pending, rev FROM notes WHERE id = ?", [id]) { stmt in
            found = (sqlite3_column_int(stmt, 0) != 0, sqlite3_column_int(stmt, 1) != 0,
                     sqlite3_column_double(stmt, 2), sqlite3_column_int(stmt, 3) != 0, sqlite3_column_int64(stmt, 4))
        }
        return found
    }

    /// Deleted here: kept as a tombstone until the server has it.
    func markDeleted(id: String, at time: Date) throws {
        try run("UPDATE notes SET deleted = 1, dirty = 1, updated_at = ?, image_pending = 0 WHERE id = ?",
                [time.timeIntervalSince1970, id])
    }

    func removeNote(id: String) throws {
        try run("DELETE FROM notes WHERE id = ?", [id])
    }

    /// Notes waiting to be sent: (note, deleted).
    func dirtyNotes() throws -> [(note: Note, deleted: Bool)] {
        var result: [(Note, Bool)] = []
        try query("SELECT \(Database.noteColumns), n.deleted FROM notes n WHERE n.dirty = 1", []) { stmt in
            result.append((Database.readNote(stmt), sqlite3_column_int(stmt, 13) != 0))
        }
        return result
    }

    /// The server took the change: no longer dirty, unless the note was edited again meanwhile.
    func markSent(id: String, updatedAt: Double, rev: Int64, imageSHA: String?, hasImage: Bool) throws {
        try run("UPDATE notes SET rev = ?, image_sha = ?, has_image = MAX(has_image, ?) WHERE id = ?",
                [rev, imageSHA, hasImage ? 1 : 0, id])
        try run("UPDATE notes SET dirty = 0 WHERE id = ? AND updated_at = ?", [id, updatedAt])
    }

    func setImageState(id: String, local: String?, pending: Bool) throws {
        try run("UPDATE notes SET image_local = ?, image_pending = ? WHERE id = ?", [local, pending ? 1 : 0, id])
    }

    func setImageUploaded(id: String, sha: String?, rev: Int64) throws {
        try run("UPDATE notes SET image_local = ?, image_sha = ?, image_pending = 0, has_image = 1, rev = MAX(rev, ?) WHERE id = ?",
                [sha, sha, rev, id])
    }

    /// Pictures made here that the server doesn't have yet (their notes are on the server already).
    func pendingImageUploads() throws -> [String] {
        var ids: [String] = []
        try query("SELECT id FROM notes WHERE image_pending = 1 AND dirty = 0 AND deleted = 0", []) { ids.append(Database.string($0, 0)) }
        return ids
    }

    /// Pictures on the server that this device doesn't have (or has an older one of): (id, sha).
    func missingImages() throws -> [(id: String, sha: String)] {
        var result: [(String, String)] = []
        try query("""
            SELECT id, image_sha FROM notes WHERE has_image = 1 AND deleted = 0 AND image_pending = 0
            AND image_sha IS NOT NULL AND (image_local IS NULL OR image_local != image_sha)
            ORDER BY updated_at DESC
            """, []) { result.append((Database.string($0, 0), Database.string($0, 1))) }
        return result
    }

    func setImageDownloaded(id: String, sha: String) throws {
        try run("UPDATE notes SET image_local = ? WHERE id = ? AND image_sha = ?", [sha, id, sha])
    }

    /// The server dropped a picture: the note has none any more.
    func clearImage(id: String) throws {
        try run("UPDATE notes SET has_image = 0, image_sha = NULL, image_local = NULL, image_pending = 0 WHERE id = ?", [id])
    }

    func noteCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM notes WHERE deleted = 0", []) { count = Int(sqlite3_column_int($0, 0)) }
        return count
    }

    func pendingCount() throws -> Int {
        var count = 0
        try query("""
            SELECT (SELECT COUNT(*) FROM notes WHERE dirty = 1 OR image_pending = 1)
                 + (SELECT COUNT(*) FROM folders WHERE dirty = 1) + (SELECT COUNT(*) FROM tag_colors WHERE dirty = 1)
            """, []) { count = Int(sqlite3_column_int($0, 0)) }
        return count
    }

    /// A different server: everything that came from the old one goes; changes not sent yet stay, for the new one.
    func forgetSynced() throws -> [String] {
        var ids: [String] = []
        try query("SELECT id FROM notes WHERE dirty = 0 AND image_pending = 0", []) { ids.append(Database.string($0, 0)) }
        try exec("""
            DELETE FROM notes WHERE dirty = 0 AND image_pending = 0;
            UPDATE notes SET rev = 0, image_sha = NULL;
            DELETE FROM folders WHERE dirty = 0;
            DELETE FROM tag_colors WHERE dirty = 0;
            DELETE FROM meta WHERE key = 'rev';
            """)
        return ids
    }

    /// folder id -> number of notes filed in it.
    func folderCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        try query("SELECT folder_id, COUNT(*) FROM notes WHERE folder_id IS NOT NULL AND deleted = 0 GROUP BY folder_id", []) { stmt in
            counts[Database.string(stmt, 0)] = Int(sqlite3_column_int(stmt, 1))
        }
        return counts
    }

    /// Ids of the notes filed in a folder.
    func notes(inFolder id: String) throws -> [Note] {
        var result: [Note] = []
        try query("SELECT \(Database.noteColumns) FROM notes n WHERE n.folder_id = ? AND n.deleted = 0", [id]) {
            result.append(Database.readNote($0))
        }
        return result
    }

    /// Every tag in use, with how many notes carry it, sorted by name.
    func allTags() throws -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        try query("SELECT tags FROM notes WHERE tags != '' AND deleted = 0", []) { stmt in
            for tag in Database.string(stmt, 0).split(separator: "\n") { counts[String(tag), default: 0] += 1 }
        }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Notes matching a search (best match first), or all notes (newest first) when the search is empty.
    func notes(matching search: String, limit: Int = 10_000) throws -> [Note] {
        var result: [Note] = []
        let readRow: (OpaquePointer) -> Void = { result.append(Database.readNote($0)) }
        if let match = Database.ftsQuery(from: search) {
            try query("""
                SELECT \(Database.noteColumns) FROM notes_fts f JOIN notes n ON n.rowid = f.rowid
                WHERE notes_fts MATCH ? AND n.deleted = 0 ORDER BY bm25(notes_fts, 10.0, 1.0, 1.0, 5.0) LIMIT ?
                """, [match, limit], readRow)
        } else {
            try query("SELECT \(Database.noteColumns) FROM notes n WHERE n.deleted = 0 ORDER BY n.created_at DESC LIMIT ?", [limit], readRow)
        }
        return result
    }

    /// Turns what the user typed into an FTS5 query: every word must match, as a prefix.
    /// `invoice acme` -> `"invoice"* "acme"*`
    static func ftsQuery(from search: String) -> String? {
        let words = search
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: - Folders

    struct FolderRow {
        var id: String
        var name: String
        var color: String?
        var createdAt: Double
        var updatedAt: Double
        var deleted: Bool
    }

    private static func readFolder(_ stmt: OpaquePointer) -> FolderRow {
        FolderRow(id: string(stmt, 0), name: string(stmt, 1), color: optionalString(stmt, 2),
                  createdAt: sqlite3_column_double(stmt, 3), updatedAt: sqlite3_column_double(stmt, 4),
                  deleted: sqlite3_column_int(stmt, 5) != 0)
    }

    func folders() throws -> [FolderRow] {
        var result: [FolderRow] = []
        try query("SELECT id, name, color, created_at, updated_at, deleted FROM folders WHERE deleted = 0", []) {
            result.append(Database.readFolder($0))
        }
        return result
    }

    func folder(id: String) throws -> FolderRow? {
        var found: FolderRow?
        try query("SELECT id, name, color, created_at, updated_at, deleted FROM folders WHERE id = ?", [id]) { found = Database.readFolder($0) }
        return found
    }

    func folderIsDirty(_ id: String) throws -> Bool {
        var dirty = false
        try query("SELECT dirty FROM folders WHERE id = ?", [id]) { dirty = sqlite3_column_int($0, 0) != 0 }
        return dirty
    }

    func saveFolder(_ f: FolderRow, dirty: Bool) throws {
        try run("""
            INSERT INTO folders (id, name, color, created_at, updated_at, deleted, dirty) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color, created_at = excluded.created_at,
                updated_at = excluded.updated_at, deleted = excluded.deleted, dirty = excluded.dirty
            """, [f.id, f.name, f.color, f.createdAt, f.updatedAt, f.deleted ? 1 : 0, dirty ? 1 : 0])
    }

    func removeFolder(id: String) throws {
        try run("DELETE FROM folders WHERE id = ?", [id])
    }

    func dirtyFolders() throws -> [FolderRow] {
        var result: [FolderRow] = []
        try query("SELECT id, name, color, created_at, updated_at, deleted FROM folders WHERE dirty = 1", []) {
            result.append(Database.readFolder($0))
        }
        return result
    }

    func markFolderSent(id: String, updatedAt: Double) throws {
        try run("UPDATE folders SET dirty = 0 WHERE id = ? AND updated_at = ?", [id, updatedAt])
        try run("DELETE FROM folders WHERE id = ? AND deleted = 1 AND dirty = 0", [id])
    }

    // MARK: - Tag colours

    struct TagRow {
        var name: String
        var color: String?
        var updatedAt: Double
    }

    /// Lowercased name -> colour, for the tags that have one.
    func tagColors() throws -> [String: String] {
        var result: [String: String] = [:]
        try query("SELECT key, color FROM tag_colors WHERE color IS NOT NULL", []) {
            result[Database.string($0, 0)] = Database.string($0, 1)
        }
        return result
    }

    func tagIsDirty(_ name: String) throws -> Bool {
        var dirty = false
        try query("SELECT dirty FROM tag_colors WHERE key = ?", [name.lowercased()]) { dirty = sqlite3_column_int($0, 0) != 0 }
        return dirty
    }

    func saveTag(_ t: TagRow, dirty: Bool) throws {
        try run("""
            INSERT INTO tag_colors (key, name, color, updated_at, dirty) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET name = excluded.name, color = excluded.color,
                updated_at = excluded.updated_at, dirty = excluded.dirty
            """, [t.name.lowercased(), t.name, t.color, t.updatedAt, dirty ? 1 : 0])
    }

    func dirtyTags() throws -> [TagRow] {
        var result: [TagRow] = []
        try query("SELECT name, color, updated_at FROM tag_colors WHERE dirty = 1", []) {
            result.append(TagRow(name: Database.string($0, 0), color: Database.optionalString($0, 1), updatedAt: sqlite3_column_double($0, 2)))
        }
        return result
    }

    func markTagSent(name: String, updatedAt: Double) throws {
        try run("UPDATE tag_colors SET dirty = 0 WHERE key = ? AND updated_at = ?", [name.lowercased(), updatedAt])
    }

    // MARK: - Settings kept with the data

    func meta(_ key: String) throws -> String? {
        var value: String?
        try query("SELECT value FROM meta WHERE key = ?", [key]) { value = Database.optionalString($0, 0) }
        return value
    }

    func setMeta(_ key: String, _ value: String?) throws {
        try run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
    }

    // MARK: - Inbox

    /// Adds an item to the inbox. If the same content is already there, moves it to the top instead.
    /// Returns true when a new row was inserted.
    @discardableResult
    func addInboxItem(kind: InboxItem.Kind, text: String, imagePath: String?, source: String,
                      sourceApp: String?, hash: String) throws -> Bool {
        let now = Date().timeIntervalSince1970
        var existing: Int64?
        try query("SELECT id FROM inbox WHERE hash = ? LIMIT 1", [hash]) { existing = sqlite3_column_int64($0, 0) }
        if let existing {
            try run("UPDATE inbox SET created_at = ?, source_app = COALESCE(?, source_app) WHERE id = ?",
                    [now, sourceApp, existing])
            return false
        }
        try run("""
            INSERT INTO inbox (kind, text, image_path, source, source_app, hash, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [kind.rawValue, text, imagePath, source, sourceApp, hash, now])
        return true
    }

    func inboxItems(limit: Int = 1000) throws -> [InboxItem] {
        var result: [InboxItem] = []
        try query("""
            SELECT id, kind, text, image_path, source, source_app, created_at, note_id
            FROM inbox ORDER BY created_at DESC LIMIT ?
            """, [limit]) { stmt in
            result.append(InboxItem(
                id: sqlite3_column_int64(stmt, 0),
                kind: InboxItem.Kind(rawValue: Database.string(stmt, 1)) ?? .text,
                text: Database.string(stmt, 2),
                imagePath: Database.optionalString(stmt, 3),
                source: Database.string(stmt, 4),
                sourceApp: Database.optionalString(stmt, 5),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                noteId: Database.optionalString(stmt, 7)))
        }
        return result
    }

    func markInboxItem(_ id: Int64, savedAs noteId: String) throws {
        try run("UPDATE inbox SET note_id = ? WHERE id = ?", [noteId, id])
    }

    func clearInboxLinks(toNote noteId: String) throws {
        try run("UPDATE inbox SET note_id = NULL WHERE note_id = ?", [noteId])
    }

    func deleteInboxItem(_ id: Int64) throws {
        try run("DELETE FROM inbox WHERE id = ?", [id])
    }

    /// Deletes inbox items beyond the newest `keep`, returning their image paths so files can be removed.
    func trimInbox(keep: Int) throws -> [String] {
        var paths: [String] = []
        let cutoff = "SELECT id FROM inbox ORDER BY created_at DESC LIMIT -1 OFFSET ?"
        try query("SELECT image_path FROM inbox WHERE id IN (\(cutoff)) AND image_path IS NOT NULL", [keep]) {
            paths.append(Database.string($0, 0))
        }
        try run("DELETE FROM inbox WHERE id IN (\(cutoff))", [keep])
        return paths
    }

    func allInboxImagePaths() throws -> [String] {
        var paths: [String] = []
        try query("SELECT image_path FROM inbox WHERE image_path IS NOT NULL", []) { paths.append(Database.string($0, 0)) }
        return paths
    }

    func clearInbox() throws {
        try exec("DELETE FROM inbox;")
    }

    // MARK: - SQLite plumbing

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw DatabaseError(description: message)
        }
    }

    private func prepare(_ sql: String, _ values: [Any?]) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let stmt = prepared else {
            throw DatabaseError(description: "\(lastError) in: \(sql)")
        }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .none:
                sqlite3_bind_null(stmt, index)
            case .some(let v as String):
                sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            case .some(let v as Double):
                sqlite3_bind_double(stmt, index, v)
            case .some(let v as Int64):
                sqlite3_bind_int64(stmt, index, v)
            case .some(let v as Int):
                sqlite3_bind_int64(stmt, index, Int64(v))
            case .some(let v):
                sqlite3_bind_text(stmt, index, "\(v)", -1, SQLITE_TRANSIENT)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ values: [Any?]) throws {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError(description: "\(lastError) in: \(sql)")
        }
    }

    private func query(_ sql: String, _ values: [Any?], _ row: (OpaquePointer) -> Void) throws {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt) }
            else if rc == SQLITE_DONE { return }
            else { throw DatabaseError(description: "\(lastError) in: \(sql)") }
        }
    }

    private static func string(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    private static func optionalString(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : string(stmt, col)
    }
}
