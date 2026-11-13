import AppKit
import Foundation
import UniformTypeIdentifiers

/// The Mac's clipboard and drag-and-drop side of the store.
extension NotesStore {
    // MARK: - Copying back to the clipboard

    // Copies made here are marked as ours, so they never come back as new Inbox entries.

    func copyToPasteboard(_ item: InboxItem) {
        if item.kind == .image, let url = item.imageURL, let data = try? Data(contentsOf: url) {
            writeImage(data)
        } else {
            writeString(item.text)
        }
    }

    func copyToPasteboard(_ note: Note) {
        if let data = imageData(for: note) {
            writeImage(data)
        } else {
            writeString(note.body.isEmpty ? note.ocrText : note.body)
        }
    }

    func copyText(_ text: String) {
        writeString(text)
    }

    private func writeString(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ownPasteboardChange = pb.changeCount
    }

    /// PNG plus TIFF, so Mail, Word, Pages and the rest all take it.
    private func writeImage(_ data: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
        pb.setData(png, forType: .png)
        if let tiff = NSImage(data: data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        ownPasteboardChange = pb.changeCount
    }

    /// For ⌘C in the notes list: SwiftUI puts this on the clipboard (ionote is in front, so the Inbox skips it).
    func copyProvider(for note: Note) -> NSItemProvider {
        if let data = imageData(for: note), let image = NSImage(data: data) {
            return NSItemProvider(object: image)
        }
        return NSItemProvider(object: (note.body.isEmpty ? note.ocrText : note.body) as NSString)
    }

    // MARK: - Dragging out

    /// What a note becomes when dragged into another app: an image file named after the note
    /// (Mail and Word attach or insert it), or its text.
    func dragProvider(for note: Note) -> NSItemProvider {
        let provider: NSItemProvider
        if let data = imageData(for: note), let url = exportFile(data, name: note.displayTitle, key: note.exportKey),
           let file = NSItemProvider(contentsOf: url) {
            provider = file
        } else {
            provider = NSItemProvider(object: (note.body.isEmpty ? note.ocrText : note.body) as NSString)
        }
        // Dropped on a folder in the sidebar, this is what says which note it is.
        let id = Data(note.id.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.ionotesNote.identifier, visibility: .ownProcess) { done in
            done(id, nil)
            return nil
        }
        return provider
    }

    func dragProvider(for item: InboxItem) -> NSItemProvider {
        if let url = imageFileURL(for: item), let provider = NSItemProvider(contentsOf: url) {
            return provider
        }
        return NSItemProvider(object: item.text as NSString)
    }
}
