import Foundation
import SwiftUI

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
    /// Which picture this device has for the note (nil until it has been fetched), so previews can follow it.
    var imageKey: String? = nil

    /// Names the exported file of the note's picture; a new picture gets a new file.
    var exportKey: String { imageKey.map { "\(id)-\($0)" } ?? id }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let line = Note.firstLine(of: body) { return line }
        if let line = Note.firstLine(of: ocrText) { return line }
        return hasImage ? "Image" : "Untitled"
    }

    var preview: String {
        let text = body.isEmpty ? ocrText : Markdown.plain(body)
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

/// A file attached to a note on the server (a PDF, another picture, a document). Its bytes are fetched when it is
/// opened; the list of them comes with the note when it syncs.
struct Attachment: Identifiable, Hashable {
    let id: String
    let noteID: String
    var name: String
    var mime: String
    var bytes: Int
    var sha: String?
    var width: Int?
    var height: Int?
    var createdAt: Double

    var isImage: Bool { mime.hasPrefix("image/") }
    var isPDF: Bool { mime == "application/pdf" }
    var symbol: String { isPDF ? "doc.richtext" : isImage ? "photo" : mime.hasPrefix("text/") ? "doc.text" : "doc" }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

/// A starting point for new notes, made in the web app (Manage › Templates) and synced here. {{date}} and the like
/// are filled in when a note is made from it (Markdown.expand).
struct NoteTemplate: Identifiable, Hashable {
    let id: String
    var name: String
    var title: String
    var body: String
    var tags: [String]
    var folderID: String?
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

    /// Notes' pictures, one file per note named by its id: the offline copy of what is on the server.
    static var noteImagesDir: URL {
        let dir = supportDir.appendingPathComponent("NoteImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func noteImageURL(_ id: String) -> URL { noteImagesDir.appendingPathComponent(id) }

    /// Attached files fetched from the server to be opened, one folder per file (its id and version), the file in it
    /// under its own name. A cache: they can always be fetched again.
    static var attachmentsDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ionotes-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Local SQLite database: the notes (an offline copy of the server's, plus changes not sent yet), their
    /// search index, and the inbox.
    static var databaseURL: URL { supportDir.appendingPathComponent("index.sqlite") }
}
