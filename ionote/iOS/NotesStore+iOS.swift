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
