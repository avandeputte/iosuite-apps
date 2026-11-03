import Foundation
import SwiftData
import SwiftUI

/// A note as stored in SwiftData and synced through the CloudKit private database.
///
/// CloudKit rules for SwiftData models: every property needs a default or must be optional,
/// no unique constraints, and schema changes after release must be additive (new optional fields).
/// This file is platform-neutral so a future iPhone/iPad target can share it.
@Model
final class NoteRecord {
    /// Stable identifier used by the local search index and the UI.
    var uuid: String = UUID().uuidString
    var title: String = ""
    var body: String = ""
    var ocrText: String = ""
    /// PNG/JPEG bytes. External storage keeps large blobs out of the row; CloudKit syncs it as an asset.
    @Attribute(.externalStorage) var imageData: Data?
    /// Where the note came from: "clipboard", "service", "screenshot" or "manual".
    var source: String = "manual"
    var sourceApp: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Added after 1.0; CloudKit only allows new fields that have a default.
    var tags: [String] = []
    var pinned: Bool = false
    /// The `uuid` of the FolderRecord this note is filed in; nil for no folder.
    var folderID: String?

    init(title: String = "", body: String = "", imageData: Data? = nil, source: String, sourceApp: String? = nil) {
        self.title = title
        self.body = body
        self.imageData = imageData
        self.source = source
        self.sourceApp = sourceApp
    }

    var snapshot: Note {
        Note(id: uuid, title: title, body: body, ocrText: ocrText, hasImage: imageData != nil,
             source: source, sourceApp: sourceApp, createdAt: createdAt, updatedAt: updatedAt,
             tags: tags, pinned: pinned, folderID: folderID)
    }
}

/// A folder notes can be filed in ("Work", "AI"). Synced like notes; notes point at it by `uuid`.
@Model
final class FolderRecord {
    var uuid: String = UUID().uuidString
    var name: String = ""
    var createdAt: Date = Date()
    /// A LabelColor raw value, or nil for the default look.
    var color: String?

    init(name: String) {
        self.name = name
    }
}

/// The colour picked for a tag. Tags themselves are just names on notes, so this only exists once
/// a tag has been given a colour. Matched by name, ignoring case.
@Model
final class TagRecord {
    var name: String = ""
    var color: String?

    init(name: String, color: String?) {
        self.name = name
        self.color = color
    }
}

struct Folder: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
    var color: LabelColor?
}

/// The colours folders and tags can have, the same set Finder uses for its tags plus a few.
enum LabelColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown, gray

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .brown: return .brown
        case .gray: return .gray
        }
    }
}

/// A lightweight copy of a note for lists and the search index (no image bytes).
struct Note: Identifiable, Hashable {
    var id: String
    var title: String
    var body: String
    var ocrText: String
    var hasImage: Bool
    var source: String
    var sourceApp: String?
    var createdAt: Date
    var updatedAt: Date
    var tags: [String]
    var pinned: Bool
    var folderID: String?

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let line = Note.firstLine(of: body) { return line }
        if let line = Note.firstLine(of: ocrText) { return line }
        return hasImage ? "Image" : "Untitled"
    }

    var preview: String {
        let text = body.isEmpty ? ocrText : body
        return String(text.replacingOccurrences(of: "\n", with: " ").prefix(160))
    }

    /// Tidies tags typed by hand: trims, drops a leading "#", removes empties and duplicates (any case).
    static func cleanTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while tag.hasPrefix("#") { tag.removeFirst() }
            tag = tag.trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { return nil }
            return tag
        }
    }

    static func firstLine(of text: String, limit: Int = 80) -> String? {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line.map { String($0.prefix(limit)) }
    }
}

/// Something that showed up on the clipboard or in the screenshots folder, waiting in the
/// inbox to be saved as a note. The inbox is local to each Mac and never synced.
struct InboxItem: Identifiable, Hashable {
    enum Kind: String { case text, image }

    var id: Int64
    var kind: Kind
    var text: String
    /// Absolute path of the image file for image items.
    var imagePath: String?
    /// "clipboard" or "screenshot".
    var source: String
    var sourceApp: String?
    var createdAt: Date
    /// Set once the item has been saved as a note.
    var noteId: String?

    var imageURL: URL? { imagePath.map { URL(fileURLWithPath: $0) } }
}

enum AppPaths {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ionotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Clipboard and screenshot images waiting in the inbox (local only).
    static var inboxImagesDir: URL {
        let dir = supportDir.appendingPathComponent("InboxImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Local SQLite database: the inbox plus the full-text search index of notes.
    static var databaseURL: URL { supportDir.appendingPathComponent("index.sqlite") }

    /// SwiftData store (synced with CloudKit).
    static var notesStoreURL: URL { supportDir.appendingPathComponent("Notes.store") }
}
