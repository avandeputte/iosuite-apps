import Foundation
import UniformTypeIdentifiers

/// Files attached to notes (PDFs, more pictures, documents). They live on the server: the note's list of them comes
/// with the note when it syncs, a file is fetched when it is opened (and kept in the cache), and attaching one sends
/// it straight away, so attaching needs the server.
extension NotesStore {
    func attachments(of noteID: String) -> [Attachment] { attachments[noteID] ?? [] }

    /// Attaches files (from a file picker, a drop or the share sheet) to a note. Pictures have their text read here
    /// first, so they can be found by it. Answers whether all of them were sent.
    @discardableResult
    func attach(files: [URL], to noteID: String) async -> Bool {
        var items: [(data: Data, name: String)] = []
        for url in files {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                lastError = "\u{201C}\(url.lastPathComponent)\u{201D} could not be read."
                continue
            }
            items.append((data, url.lastPathComponent))
        }
        return await attach(data: items, to: noteID)
    }

    @discardableResult
    func attach(data items: [(data: Data, name: String)], to noteID: String) async -> Bool {
        guard !items.isEmpty else { return true }
        guard ServerConfig.serverURL != nil else {
            lastError = "Attaching files needs the ioNotes server. Connect to it in Settings."
            return false
        }
        transferring.insert(noteID)
        defer { transferring.remove(noteID) }
        guard await noteIsOnServer(noteID) else {
            lastError = "The note isn't on the server yet, so files can't be attached to it. Try again once it has synced."
            return false
        }
        var allSent = true
        for item in items {
            let mime = Self.mimeType(name: item.name, data: item.data)
            var text: String?
            if mime.hasPrefix("image/") {
                let found = await OCR.recognizeText(in: item.data)
                text = found
            }
            do {
                let note = try await client.uploadAttachment(item.data, id: UUID().uuidString, noteID: noteID, name: item.name,
                                                             mime: mime, text: text)
                applyAttachments(from: note, noteID: noteID)
            } catch {
                allSent = false
                lastError = "\u{201C}\(item.name)\u{201D} was not attached: \(error.localizedDescription)"
            }
        }
        syncSoon(after: 1)
        return allSent
    }

    /// The file on this device, fetched from the server if it isn't in the cache yet (nil: it couldn't be).
    func localFile(for a: Attachment) async -> URL? {
        let dir = AppPaths.attachmentsDir.appendingPathComponent(a.id + "-" + String((a.sha ?? "x").prefix(12)), isDirectory: true)
        let safeName = a.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent(safeName.isEmpty ? "file" : safeName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        transferring.insert(a.id)
        defer { transferring.remove(a.id) }
        do {
            guard let data = try await client.downloadAttachment(id: a.id, noteID: a.noteID) else {
                lastError = "\u{201C}\(a.name)\u{201D} is no longer on the server."
                return nil
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            lastError = "\u{201C}\(a.name)\u{201D} could not be fetched: \(error.localizedDescription)"
            return nil
        }
    }

    func removeAttachment(_ a: Attachment) async {
        transferring.insert(a.id)
        defer { transferring.remove(a.id) }
        do {
            let note = try await client.deleteAttachment(id: a.id, noteID: a.noteID)
            applyAttachments(from: note, noteID: a.noteID)
            let dir = AppPaths.attachmentsDir.appendingPathComponent(a.id + "-" + String((a.sha ?? "x").prefix(12)), isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
        } catch {
            lastError = "\u{201C}\(a.name)\u{201D} was not removed: \(error.localizedDescription)"
        }
    }

    /// The note's list of files as the server answered it.
    private func applyAttachments(from note: [String: Any], noteID: String) {
        guard let files = Self.attachments(of: note, noteID: noteID) else { return }
        do {
            try db.setAttachments(noteID: noteID, files)
        } catch {
            report(error)
        }
        reloadNotes()
    }

    /// Syncs until a note made here is on the server (a few tries; false when it isn't, e.g. offline).
    private func noteIsOnServer(_ id: String) async -> Bool {
        for _ in 0..<6 {
            if let state = try? db.syncState(ofNote: id), state.rev > 0, !state.deleted {
                if !state.dirty { return true }
            } else if (try? db.syncState(ofNote: id)) == nil {
                return false
            }
            while syncing { try? await Task.sleep(for: .milliseconds(300)) }
            await sync()
            if case .offline = syncStatus { break }
            if case .signedOut = syncStatus { break }
        }
        return (try? db.syncState(ofNote: id))?.rev ?? 0 > 0
    }

    static func mimeType(name: String, data: Data) -> String {
        if data.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "application/pdf" }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType { return mime }
        let image = ImageCoding.mimeType(of: data)
        return image.hasPrefix("image/") ? image : "application/octet-stream"
    }
}
