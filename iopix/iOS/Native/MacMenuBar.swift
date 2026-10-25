#if targetEnvironment(macCatalyst)
import SwiftUI
import Combine

/// On a Mac the app keeps an icon in the menu bar (from the Mac-only plug-in inside the app): what is being sent,
/// new photos to look at, and quick ways to send or open iopix.
@objc(IopixStatusBarProtocol) protocol IopixStatusBarProtocol: NSObjectProtocol {
    init()
    func setUp(_ act: @escaping (String) -> Void)
    func update(_ state: [String: Any])
    func activate()
}

@MainActor
final class MacMenuBar {
    static let shared = MacMenuBar()
    private var bar: IopixStatusBarProtocol?
    private var watch: AnyCancellable?

    func start() {
        guard bar == nil,
              let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("iopixMacBridge.bundle"),
              let bundle = Bundle(url: url), bundle.load(),
              let type = bundle.principalClass as? IopixStatusBarProtocol.Type else { return }
        let b = type.init()
        b.setUp { action in Task { @MainActor in MacMenuBar.shared.handle(action) } }
        bar = b
        let queue = UploadQueue.shared
        watch = queue.objectWillChange
            .merge(with: PhotosWatcher.shared.objectWillChange)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.push() }
        push()
    }

    private func push() {
        let q = UploadQueue.shared
        let sending = q.items.first { $0.state == .sending }?.name ?? ""
        bar?.update([
            "signedIn": q.account?.signedIn == true ? (q.account?.name ?? "you") : "",
            "reviewing": q.reviewing.count,
            "sending": sending,
            "waiting": q.pending.count,
            "offline": q.offline,
            "watching": PhotosWatcher.shared.enabled,
            "failed": q.items.filter { $0.state == .failed }.count,
            "goesTo": Destination.current.example(),
        ])
    }

    private func handle(_ action: String) {
        switch action {
        case "watch":
            Task { await PhotosWatcher.shared.setEnabled(!PhotosWatcher.shared.enabled); push() }
        case "retry":
            UploadQueue.shared.retryFailed()
        case "send", "review":
            NotificationCenter.default.post(name: .iopixSendPhotos, object: nil)
        case "signin":
            NotificationCenter.default.post(name: .iopixSignIn, object: nil)
        default:
            break  // "open": the plug-in already brought the app in front
        }
        bar?.activate()
    }
}
#endif
