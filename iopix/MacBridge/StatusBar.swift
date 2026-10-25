import AppKit

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
