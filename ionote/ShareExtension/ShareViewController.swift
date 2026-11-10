import Social
import UIKit
import UniformTypeIdentifiers

/// "ioNotes" in the share sheet: text, links, pictures, PDFs and other files become a note (a comment can be added).
/// The extension only writes the share into the App Group container; the app makes the note and sends it to the
/// server the next time it is opened (see ShareInbox).
final class ShareViewController: SLComposeServiceViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ioNotes"
        placeholder = "Add a comment (optional)"
        navigationController?.navigationBar.tintColor = UIColor(red: 0.0, green: 0.56, blue: 0.56, alpha: 1)
    }

    override func isContentValid() -> Bool { true }

    override func configurationItems() -> [Any]! { [] }

    override func didSelectPost() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let comment = contentText ?? ""
        Task { @MainActor in
            await Self.save(providers: providers, comment: comment)
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private static func save(providers: [NSItemProvider], comment: String) async {
        guard let dir = ShareInbox.newFolder() else { return }
        var item = ShareInbox.Item(text: comment.trimmingCharacters(in: .whitespacesAndNewlines))
        var used = Set<String>()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await loadURL(provider), !url.isFileURL {
                item.url = url.absoluteString
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let text = await loadText(provider) {
                if !item.text.contains(text) { item.text = item.text.isEmpty ? text : item.text + "\n\n" + text }
                continue
            }
            let types = provider.registeredTypeIdentifiers
            guard let type = types.first(where: { UTType($0)?.conforms(to: .image) == true })
                    ?? types.first(where: { UTType($0)?.conforms(to: .pdf) == true })
                    ?? types.first(where: { UTType($0)?.conforms(to: .data) == true }) else { continue }
            if let name = await copyFile(provider, type: type, into: dir, used: used) {
                used.insert(name)
                item.files.append(name)
            }
        }
        if item.text.isEmpty, item.url == nil, item.files.isEmpty {
            ShareInbox.done(dir)
            return
        }
        try? ShareInbox.write(item, to: dir)
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in done.resume(returning: (object as? NSURL) as URL?) }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in done.resume(returning: object as? String) }
        }
    }

    /// Copies the shared file into the share's folder; answers its name there.
    private static func copyFile(_ provider: NSItemProvider, type: String, into dir: URL, used: Set<String>) async -> String? {
        await withCheckedContinuation { done in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { done.resume(returning: nil); return }
                var name = provider.suggestedName.map { n -> String in
                    let ext = url.pathExtension
                    return ext.isEmpty || n.lowercased().hasSuffix("." + ext.lowercased()) ? n : n + "." + ext
                } ?? url.lastPathComponent
                name = name.replacingOccurrences(of: "/", with: "-")
                if used.contains(name) { name = String(UUID().uuidString.prefix(4)) + "-" + name }
                do {
                    try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))
                    done.resume(returning: name)
                } catch {
                    done.resume(returning: nil)
                }
            }
        }
    }
}
