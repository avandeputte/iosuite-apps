import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "iopix" in the share sheet: sends what was shared straight to iopix, with the app's sign-in.
final class ShareViewController: UIViewController {
    private lazy var model = ShareModel(context: extensionContext)

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        model.start()
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable {
        case preparing
        case sending(index: Int, total: Int, progress: Double)
        case finished(String)
        case failed(String)
    }

    @Published var phase: Phase = .preparing
    private weak var context: NSExtensionContext?
    private var work: Task<Void, Never>?

    init(context: NSExtensionContext?) { self.context = context }

    func start() { work = Task { await run() } }

    private func run() async {
        Self.sweep()  // folders a share left behind when the sheet was swiped away
        BackgroundUploads.sweepOutbox()
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
            .filter { p in [UTType.movie, UTType.image].contains { p.hasItemConformingToTypeIdentifier($0.identifier) } }
        guard !providers.isEmpty else { phase = .failed("Only photos and videos can be sent to iopix."); return }
        guard AppConfig.hasServer else { phase = .failed("Open the iopix app and connect it to your server first."); return }

        do {
            let account = try await IopixClient.shared.account()
            guard account.canWrite else {
                phase = .failed(account.signedIn ? "\(account.name ?? "This account") can look at photos in iopix but not add them."
                                                 : "Open the iopix app and sign in first.")
                return
            }
        } catch IopixError.needsSignIn {
            phase = .failed("Open the iopix app and sign in first.")
            return
        } catch {
            phase = .failed("iopix can't be reached right now. \(error.localizedDescription)")
            return
        }

        // one at a time: a photo is fetched (from iCloud when needed), sent, and its copy removed before the next
        var added = 0, already = 0, queued = 0, notAdded: [String] = []
        let total = providers.count
        for (i, p) in providers.enumerated() {
            if Task.isCancelled { return }
            phase = .sending(index: i, total: total, progress: 0)
            guard let file = await Self.load(p) else {
                notAdded.append("\(p.suggestedName ?? "One item"): couldn't be read (not downloaded from iCloud?)")
                continue
            }
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            do {
                // iopix 1.78 and later: iOS sends it in the background, so the sheet can close right away
                if let prepared = try await IopixClient.shared.prepareUpload(file: file, name: file.lastPathComponent, folder: BackgroundUploads.outbox) {
                    switch prepared {
                    case .alreadyThere: already += 1
                    case .request(let r, let body):
                        BackgroundUploads.shared(BackgroundUploads.shareIdentifier).send(r, body: body, tag: file.lastPathComponent)
                        queued += 1
                    }
                    continue
                }
                let outcome = try await IopixClient.shared.upload(file: file, name: file.lastPathComponent) { pr in
                    Task { @MainActor in self.phase = .sending(index: i, total: total, progress: pr) }
                }
                switch outcome {
                case .added: added += 1
                case .alreadyThere: already += 1
                case .skipped(let why): notAdded.append("\(file.lastPathComponent): \(why)")
                }
            } catch {
                phase = .failed(error.localizedDescription + (added > 0 ? " \(Self.count(added)) were sent before that." : ""))
                return
            }
        }
        var lines: [String] = []
        if added > 0 { lines.append("\(Self.count(added)) sent to iopix.") }
        if queued > 0 { lines.append("\(Self.count(queued)) on \(queued == 1 ? "its" : "their") way to iopix. It carries on after you close this; the iopix app lists it when done.") }
        if already > 0 { lines.append("\(Self.count(already)) \(already == 1 ? "was" : "were") already in iopix.") }
        lines += notAdded
        phase = .finished(lines.joined(separator: "\n"))
        if notAdded.isEmpty {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            close()
        }
    }

    private static func count(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }

    /// Leftovers of earlier shares (the sheet swiped away mid-send).
    private static func sweep() {
        let tmp = FileManager.default.temporaryDirectory
        for d in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where d.hasPrefix("share-") {
            let url = tmp.appendingPathComponent(d)
            // only old ones: another share may be running right now
            if let made = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate, Date().timeIntervalSince(made) > 3600 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// The shared photo or video as a file of its own.
    private static func load(_ p: NSItemProvider) async -> URL? {
        guard let type = [UTType.movie, UTType.image].first(where: { p.hasItemConformingToTypeIdentifier($0.identifier) }) else { return nil }
        return await withCheckedContinuation { cont in
            p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { cont.resume(returning: nil); return }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
                var name = url.lastPathComponent
                if let suggested = p.suggestedName, !suggested.isEmpty, !url.pathExtension.isEmpty, !suggested.contains(".") {
                    name = "\(suggested).\(url.pathExtension)"
                }
                let dst = dir.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: dst)  // the original goes away when this callback returns
                    cont.resume(returning: dst)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private var closed = false

    func close() {
        guard !closed else { return }  // the timer and the Done button both call this
        closed = true
        context?.completeRequest(returningItems: nil)
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        work?.cancel()
        context?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                switch model.phase {
                case .preparing:
                    ProgressView()
                    Text("Getting ready…")
                case .sending(let index, let total, let progress):
                    ProgressView(value: progress).frame(maxWidth: 260)
                    Text(total == 1 ? "Sending to iopix…" : "Sending \(index + 1) of \(total) to iopix…")
                    Text("Keep this open until it's done.").font(.footnote).foregroundStyle(.secondary)
                case .finished(let text):
                    Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                    Text(text).multilineTextAlignment(.center)
                case .failed(let text):
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                    Text(text).multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("iopix")
            .toolbar { ToolbarItem(placement: .principal) { Brand.name(onLight: true).font(.headline) } }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .sending = model.phase { Button("Cancel") { model.cancel() } }
                    else if case .preparing = model.phase { Button("Cancel") { model.cancel() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    switch model.phase {
                    case .finished, .failed: Button("Done") { model.close() }
                    default: EmptyView()
                    }
                }
            }
        }
    }
}
