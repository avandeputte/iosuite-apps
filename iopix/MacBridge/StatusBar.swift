import AppKit
import ServiceManagement

/// The Mac-only part of the iPhone/iPad app when it runs on a Mac (Mac Catalyst): the icon in the menu bar. The
/// app loads this bundle, gives it a way to ask for things ("send", "review"...), and tells it what to show.
@objc(IopixStatusBarProtocol) public protocol IopixStatusBarProtocol: NSObjectProtocol {
    init()
    /// `act` is called with: open, send, review, watch, retry, signin, quit.
    func setUp(_ act: @escaping (String) -> Void)
    /// What the menu shows: signedIn (name or ""), reviewing (count), sending (name or ""), waiting (count),
    /// offline (bool), watching (bool), failed (count), goesTo (folder or "").
    func update(_ state: [String: Any])
    /// Brings the app in front (Catalyst has no direct way).
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
}

@objc(IopixStatusBar) public final class IopixStatusBar: NSObject, IopixStatusBarProtocol, NSMenuDelegate {
    private var item: NSStatusItem?
    private var act: (String) -> Void = { _ in }
    private var state: [String: Any] = [:]

    public required override init() { super.init() }

    public func setUp(_ act: @escaping (String) -> Void) {
        self.act = act
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon(busy: false, badge: false)
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        rebuild(menu)
    }

    public func update(_ state: [String: Any]) {
        self.state = state
        let busy = (state["sending"] as? String ?? "").isEmpty == false
        let badge = (state["reviewing"] as? Int ?? 0) > 0
        item?.button?.image = Self.icon(busy: busy, badge: badge)
        if let menu = item?.menu { rebuild(menu) }
    }

    public func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    public func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

    // MARK: Dock

    private var dockBar: NSProgressIndicator?

    public func dock(_ badge: String?, progress: Double) {
        let tile = NSApp.dockTile
        if dockBar == nil {
            let view = NSView(frame: NSRect(origin: .zero, size: tile.size))
            let icon = NSImageView(frame: view.bounds)
            icon.image = NSApp.applicationIconImage
            icon.autoresizingMask = [.width, .height]
            view.addSubview(icon)
            let bar = NSProgressIndicator(frame: NSRect(x: 14, y: 10, width: tile.size.width - 28, height: 16))
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.isHidden = true
            view.addSubview(bar)
            tile.contentView = view
            dockBar = bar
        }
        tile.badgeLabel = badge
        dockBar?.isHidden = progress < 0
        if progress >= 0 { dockBar?.doubleValue = min(1, progress) }
        tile.display()
    }

    // MARK: files and the desktop

    public func pickFolders(_ message: String, _ done: @escaping ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = message
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { r in done(r == .OK ? panel.urls.map(\.path) : []) }
    }

    public func setWallpaper(_ path: String) {
        let file = URL(fileURLWithPath: path)
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true])
        }
    }

    private var mountObserver: NSObjectProtocol?

    public func watchVolumes(_ mounted: @escaping (String) -> Void) {
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { mounted(url.path) }
        }
    }

    public func openPath(_ path: String) {
        if path.hasPrefix("/") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        else if let url = URL(string: path) { NSWorkspace.shared.open(url) }
    }

    // MARK: open at login

    public func loginItem() -> Bool { SMAppService.mainApp.status == .enabled }

    public func setLoginItem(_ on: Bool) -> String {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Finder Services

    private var send: ([String]) -> Void = { _ in }

    public func offerServices(_ send: @escaping ([String]) -> Void) {
        self.send = send
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// Finder › right-click › Services (or Quick Actions) › Send to iopix Native (NSServices in the app's Info.plist).
    @objc public func sendToIopixNative(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        send(urls.map(\.path))
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let name = state["signedIn"] as? String ?? ""
        if name.isEmpty {
            menu.addItem(entry("Sign in to iopix…", "signin"))
        } else {
            menu.addItem(note("Signed in as \(name)"))
        }
        menu.addItem(.separator())
        let watching = NSMenuItem(title: "Look for new photos in Photos", action: #selector(pick(_:)), keyEquivalent: "")
        watching.target = self
        watching.representedObject = "watch"
        watching.state = (state["watching"] as? Bool ?? false) ? .on : .off
        menu.addItem(watching)
        let reviewing = state["reviewing"] as? Int ?? 0
        if reviewing > 0 {
            menu.addItem(entry(reviewing == 1 ? "1 new photo to look at…" : "\(reviewing) new photos to look at…", "review"))
        }
        menu.addItem(entry("Send photos to iopix…", "send", key: "u"))
        if let goes = state["goesTo"] as? String, !goes.isEmpty { menu.addItem(note("Goes to \(goes) in iopix")) }
        let sending = state["sending"] as? String ?? ""
        let waiting = state["waiting"] as? Int ?? 0
        if !sending.isEmpty || waiting > 0 {
            menu.addItem(.separator())
            if !sending.isEmpty { menu.addItem(note("Sending \(sending)")) }
            let more = sending.isEmpty ? waiting : max(0, waiting - 1)
            if more > 0 { menu.addItem(note("\(more) waiting\((state["offline"] as? Bool ?? false) ? " for a connection" : "")")) }
        }
        let failed = state["failed"] as? Int ?? 0
        if failed > 0 {
            menu.addItem(note(failed == 1 ? "1 could not be sent" : "\(failed) could not be sent"))
            menu.addItem(entry("Try again", "retry"))
        }
        menu.addItem(.separator())
        menu.addItem(entry("Open iopix", "open", key: "o"))
        menu.addItem(entry("Quit iopix", "quit", key: "q"))
    }

    private func entry(_ title: String, _ action: String, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: key)
        i.target = self
        i.representedObject = action
        return i
    }

    private func note(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? String else { return }
        if a == "quit" { NSApp.terminate(nil); return }
        if a != "watch" && a != "retry" { NSApp.activate(ignoringOtherApps: true) }
        act(a)
    }

    /// The menu bar picture: the app's mark (a photo frame), filled while sending, with a dot when new photos wait.
    private static func icon(busy: Bool, badge: Bool) -> NSImage? {
        let name = busy ? "photo.on.rectangle.angled" : "photo.on.rectangle"
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "iopix")
        guard badge, let base else { base?.isTemplate = true; return base }
        let size = NSSize(width: 20, height: 16)
        let img = NSImage(size: size, flipped: false) { r in
            base.draw(in: NSRect(x: 0, y: 0, width: 18, height: 15))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.width - 7, y: r.height - 7, width: 7, height: 7)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
