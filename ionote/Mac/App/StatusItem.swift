import AppKit

/// The menu bar icon. A click opens the ionotes window; a right-click (or Control-click) shows a small menu.
@MainActor
final class StatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    override init() {
        super.init()
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "ionotes")
        button.toolTip = "ionotes"
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        Log.app.info("menu bar icon clicked: \(String(describing: event?.type), privacy: .public)")
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            Router.showMain()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open ionotes", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let capture = menu.addItem(withTitle: "Keep What I Copy", action: #selector(toggleClipboard), keyEquivalent: "")
        capture.target = self
        capture.state = Prefs.bool(Prefs.clipboardEnabled) ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit ionotes", action: #selector(quit), keyEquivalent: "q").target = self
        // Show the menu just this once, then go back to opening the window on click.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func open() { Router.showMain() }

    @objc private func toggleClipboard() {
        UserDefaults.standard.set(!Prefs.bool(Prefs.clipboardEnabled), forKey: Prefs.clipboardEnabled)
    }

    @objc private func settings() { Router.showSettings() }

    @objc private func quit() {
        AppDelegate.reallyQuit = true
        NSApp.terminate(nil)
    }
}
