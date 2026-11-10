import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The iPhone and iPad side of the store: copying out, pasting in and adding photos.
extension NotesStore {
    func copyToPasteboard(_ note: Note) {
        if let data = imageData(for: note), let image = UIImage(data: data) {
            UIPasteboard.general.image = image
        } else {
            UIPasteboard.general.string = note.body.isEmpty ? note.ocrText : note.body
        }
    }

    func copyText(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// What Paste brought in (from the system Paste button, so iOS doesn't ask each time):
    /// pictures become image notes (their text is read for search), text and links text notes.
    /// Returns the last note made, to open it.
    @discardableResult
    func addPasted(_ providers: [NSItemProvider], inFolder folderID: String?) async -> Note? {
        var last: Note?
        for provider in providers {
            var note: Note?
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let data = await NotesStore.loadData(provider, type: .image) {
                note = createImageNote(data: data, source: "clipboard")
            } else if provider.canLoadObject(ofClass: NSString.self), let text = await NotesStore.loadString(provider) {
                note = createTextNote(text, source: "clipboard")
            } else if provider.canLoadObject(ofClass: NSURL.self), let url = await NotesStore.loadURL(provider) {
                note = createTextNote(url.absoluteString, source: "clipboard")
            }
            if let made = note {
                if let folderID { moveNote(id: made.id, toFolder: folderID) }
                last = made
            }
        }
        return last
    }

    /// Photos and screenshots picked from the photo library become image notes.
    @discardableResult
    func addPhotos(_ items: [PhotosPickerItem], inFolder folderID: String?) async -> Note? {
        var last: Note?
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let made = createImageNote(data: data, source: "photo") else { continue }
            if let folderID { moveNote(id: made.id, toFolder: folderID) }
            last = made
        }
        return last
    }

    /// Shares from the share sheet (ShareInbox) made into notes: pictures as a picture note, text and links as the
    /// note's text, other files attached. A share stays until its files are on the server, and is tried again.
    func importShares() async {
        guard !importingShares else { return }
        importingShares = true
        defer { importingShares = false }
        for (dir, var item) in ShareInbox.pending() {
            var files = item.files.compactMap { name -> (data: Data, name: String)? in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
                return (data, name)
            }
            var noteID = item.noteID.flatMap { id in (try? db.note(id: id)) != nil ? id : nil }
            if noteID == nil {
                let text = [item.text, item.url ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
                var made: Note?
                if let first = files.first, ImageCoding.mimeType(of: first.data).hasPrefix("image/") {
                    made = createImageNote(data: first.data, title: text.isEmpty ? nil : Note.firstLine(of: text), source: "share")
                    if let made, !text.isEmpty { updateNote(id: made.id, title: made.title, body: text) }
                    if made != nil { files.removeFirst() }
                } else if !text.isEmpty {
                    made = createTextNote(text, source: "share")
                } else if let first = files.first {
                    made = createNote(title: first.name, body: "", source: "share")
                }
                guard let made else { ShareInbox.done(dir); continue }
                if let folder = selectedFolder { moveNote(id: made.id, toFolder: folder) }
                noteID = made.id
                item.noteID = made.id
                item.files = files.map(\.name)
                if files.isEmpty { ShareInbox.done(dir); continue }
                try? ShareInbox.write(item, to: dir)
            }
            guard let noteID else { continue }
            if files.isEmpty || ServerConfig.serverURL == nil {
                if files.isEmpty { ShareInbox.done(dir) }
                continue
            }
            let saved = lastError
            if await attach(data: files, to: noteID) {
                ShareInbox.done(dir)
            } else {
                lastError = saved  // offline: tried again next time, no alert
                if Date().timeIntervalSince1970 - item.createdAt > 7 * 86400 { ShareInbox.done(dir) }  // gave up after a week
            }
        }
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { done in
            _ = provider.loadDataRepresentation(for: type) { data, _ in done.resume(returning: data) }
        }
    }

    private static func loadString(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in done.resume(returning: object as? String) }
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in done.resume(returning: (object as? NSURL) as URL?) }
        }
    }
}
