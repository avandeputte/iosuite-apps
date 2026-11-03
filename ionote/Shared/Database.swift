import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DatabaseError: Error, CustomStringConvertible {
    let description: String
}

/// Local SQLite database holding the clipboard inbox and a full-text index (FTS5) of the notes.
/// The notes themselves live in SwiftData (synced with iCloud); this index is rebuilt from them.
/// Used from the main thread only.
final class Database {
    private var db: OpaquePointer?

    init(url: URL) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw DatabaseError(description: "Could not open database at \(url.path)")
        }
        try migrateNotesIndex()
        try exec(Database.schema)
    }

    /// The notes index is only a cache of SwiftData, so a new layout simply drops it; `reindex()` refills it.
    private static let notesIndexVersion: Int32 = 2

    private func migrateNotesIndex() throws {
        var version: Int32 = 0
        try query("PRAGMA user_version", []) { version = sqlite3_column_int($0, 0) }
        guard version != Database.notesIndexVersion else { return }
        try exec("""
            DROP TRIGGER IF EXISTS notes_ai; DROP TRIGGER IF EXISTS notes_ad; DROP TRIGGER IF EXISTS notes_au;
            DROP TABLE IF EXISTS notes_fts; DROP TABLE IF EXISTS notes;
            PRAGMA user_version = \(Database.notesIndexVersion);
            """)
    }

    deinit { sqlite3_close(db) }

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
        version REAL NOT NULL DEFAULT 0,
        tags TEXT NOT NULL DEFAULT '',
        pinned INTEGER NOT NULL DEFAULT 0,
        folder_id TEXT
    );

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
    CREATE TRIGGER IF NOT EXISTS notes_au AFTER UPDATE ON notes BEGIN
        INSERT INTO notes_fts(notes_fts, rowid, title, body, ocr_text, tags) VALUES ('delete', old.rowid, old.title, old.body, old.ocr_text, old.tags);
        INSERT INTO notes_fts(rowid, title, body, ocr_text, tags) VALUES (new.rowid, new.title, new.body, new.ocr_text, new.tags);
    END;

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

    // MARK: - Notes index

    func upsert(_ note: Note, version: Double) throws {
        try run("""
            INSERT INTO notes (id, title, body, ocr_text, has_image, source, source_app, created_at, updated_at, version, tags, pinned, folder_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title, body = excluded.body, ocr_text = excluded.ocr_text,
                has_image = excluded.has_image, source = excluded.source, source_app = excluded.source_app,
                created_at = excluded.created_at, updated_at = excluded.updated_at, version = excluded.version,
                tags = excluded.tags, pinned = excluded.pinned, folder_id = excluded.folder_id
            """,
            [note.id, note.title, note.body, note.ocrText, note.hasImage ? 1 : 0, note.source, note.sourceApp,
             note.createdAt.timeIntervalSince1970, note.updatedAt.timeIntervalSince1970, version,
             note.tags.joined(separator: "\n"), note.pinned ? 1 : 0, note.folderID])
    }

    func deleteNote(id: String) throws {
        try run("DELETE FROM notes WHERE id = ?", [id])
    }

    /// id -> indexed version (the note's updatedAt), used to decide which notes need re-indexing.
    func indexedVersions() throws -> [String: Double] {
        var result: [String: Double] = [:]
        try query("SELECT id, version FROM notes", []) { stmt in
            result[Database.string(stmt, 0)] = sqlite3_column_double(stmt, 1)
        }
        return result
    }

    func clearNotesIndex() throws {
        try exec("DELETE FROM notes;")
    }

    /// folder id -> number of notes filed in it.
    func folderCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        try query("SELECT folder_id, COUNT(*) FROM notes WHERE folder_id IS NOT NULL GROUP BY folder_id", []) { stmt in
            counts[Database.string(stmt, 0)] = Int(sqlite3_column_int(stmt, 1))
        }
        return counts
    }

    /// Every tag in use, with how many notes carry it, sorted by name.
    func allTags() throws -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        try query("SELECT tags FROM notes WHERE tags != ''", []) { stmt in
            for tag in Database.string(stmt, 0).split(separator: "\n") { counts[String(tag), default: 0] += 1 }
        }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Notes matching a search (best match first), or all notes (newest first) when the search is empty.
    func notes(matching search: String, limit: Int = 10_000) throws -> [Note] {
        let columns = "n.id, n.title, n.body, n.ocr_text, n.has_image, n.source, n.source_app, n.created_at, n.updated_at, n.tags, n.pinned, n.folder_id"
        var result: [Note] = []
        let readRow: (OpaquePointer) -> Void = { stmt in
            result.append(Note(
                id: Database.string(stmt, 0),
                title: Database.string(stmt, 1),
                body: Database.string(stmt, 2),
                ocrText: Database.string(stmt, 3),
                hasImage: sqlite3_column_int(stmt, 4) != 0,
                source: Database.string(stmt, 5),
                sourceApp: Database.optionalString(stmt, 6),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
                tags: Database.string(stmt, 9).split(separator: "\n").map(String.init),
                pinned: sqlite3_column_int(stmt, 10) != 0,
                folderID: Database.optionalString(stmt, 11)))
        }
        if let match = Database.ftsQuery(from: search) {
            try query("""
                SELECT \(columns) FROM notes_fts f JOIN notes n ON n.rowid = f.rowid
                WHERE notes_fts MATCH ? ORDER BY bm25(notes_fts, 10.0, 1.0, 1.0, 5.0) LIMIT ?
                """, [match, limit], readRow)
        } else {
            try query("SELECT \(columns) FROM notes n ORDER BY n.created_at DESC LIMIT ?", [limit], readRow)
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
