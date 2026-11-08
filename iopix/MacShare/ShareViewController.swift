import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "iopix" in the Share menu of Finder, Photos, Preview and Safari: the shared photos are handed to the iopix app
/// (through the App Group folder), which sends them.
final class ShareViewController: NSViewController {
    private let model = ShareModel()

    override func loadView() {
        view = NSHostingView(rootView: ShareStatus(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 380, height: 150)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        model.extensionContext = extensionContext
        Task { @MainActor in
            let n = await model.hand(providers)
            try? await Task.sleep(nanoseconds: n > 0 ? 900_000_000 : 1_800_000_000)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    @Published var text = "Handing to ioPix…"

    weak var extensionContext: NSExtensionContext?

    /// A name not yet used in the folder (two IMG_0001.JPG from different folders both arrive).
    private func free(_ name: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent(name)
        var n = 2
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    func hand(_ providers: [NSItemProvider]) async -> Int {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "69M2JRAT8P.net.iothing.iopix")?
            .appendingPathComponent("Inbox", isDirectory: true) else {
            text = "ioPix can't be reached from here. Open the ioPix app and try again."
            return 0
        }
        // written as "<id>.tmp" and renamed when complete, so the app never picks up a half-copied batch
        let id = UUID().uuidString
        let inbox = folder.appendingPathComponent(id + ".tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var n = 0
        for p in providers {
            if await copy(p, into: inbox) { n += 1 }
        }
        if n == 0 {
            try? FileManager.default.removeItem(at: inbox)
            text = "Only photos and videos can be sent to ioPix."
            return 0
        }
        try? FileManager.default.moveItem(at: inbox, to: folder.appendingPathComponent(id, isDirectory: true))
        if let url = URL(string: "iopix://inbox") {
            extensionContext?.open(url) { ok in if !ok { NSWorkspace.shared.open(url) } }
        }
        text = n == 1 ? "1 item handed to ioPix." : "\(n) items handed to ioPix."
        return n
    }

    private func copy(_ p: NSItemProvider, into folder: URL) async -> Bool {
        guard let type = [UTType.movie, UTType.image, UTType.fileURL].first(where: { p.hasItemConformingToTypeIdentifier($0.identifier) }) else { return false }
        if type == .fileURL {  // a file from Finder: copy it if it is a photo or video
            let url: URL? = await withCheckedContinuation { c in
                _ = p.loadObject(ofClass: NSURL.self) { obj, _ in c.resume(returning: obj as? URL) }
            }
            guard let url, let t = UTType(filenameExtension: url.pathExtension), t.conforms(to: .image) || t.conforms(to: .movie) else { return false }
            return (try? FileManager.default.copyItem(at: url, to: free(url.lastPathComponent, in: folder))) != nil
        }
        return await withCheckedContinuation { c in
            p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { c.resume(returning: false); return }
                var name = url.lastPathComponent
                if let s = p.suggestedName, !s.isEmpty, !s.contains("."), !url.pathExtension.isEmpty { name = "\(s).\(url.pathExtension)" }
                c.resume(returning: (try? FileManager.default.copyItem(at: url, to: self.free(name, in: folder))) != nil)
            }
        }
    }
}

struct ShareStatus: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up.circle.fill").font(.system(size: 36)).foregroundStyle(Color.accentColor)
            Text(model.text).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(width: 380, height: 150)
    }
}
