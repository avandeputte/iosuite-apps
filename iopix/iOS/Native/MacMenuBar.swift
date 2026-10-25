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
    /// The Dock icon: a badge ("3", "5 new", nil) and a progress bar (0...1; below 0 hides it).
    func dock(_ badge: String?, progress: Double)
    /// An open panel for folders; `done` gets the chosen paths (none when cancelled).
    func pickFolders(_ message: String, _ done: @escaping ([String]) -> Void)
    /// Puts the picture at `path` on every screen's desktop.
    func setWallpaper(_ path: String)
    /// `mounted` is called with the path of each drive that appears from now on.
    func watchVolumes(_ mounted: @escaping (String) -> Void)
    /// Opens a file, folder or URL ("x-apple.systempreferences:…") with the Mac's default app.
    func openPath(_ path: String)
    /// Open at login (SMAppService): whether it is on, and turning it on or off ("" or why it failed).
    func loginItem() -> Bool
    func setLoginItem(_ on: Bool) -> String
    /// Finder's right-click › Services › Send to iopix Native: `send` gets the file and folder paths.
    func offerServices(_ send: @escaping ([String]) -> Void)
    /// Shows or hides the windows' toolbars (hidden while the photo viewer is open).
    func showToolbars(_ on: Bool)
}

@MainActor
final class MacMenuBar {
    static let shared = MacMenuBar()
    private(set) var bar: IopixStatusBarProtocol?
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
