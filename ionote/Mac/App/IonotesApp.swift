import AppKit
import SwiftUI

@main
struct IonotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = NotesStore.shared

    var body: some Scene {
        // The main window is an AppKit window the menu bar icon can always bring back (see Router);
        // SwiftUI only provides Settings and the menu commands.
        Settings {
            SettingsView()
                .environmentObject(store)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { NotificationCenter.default.post(name: .ionotesNewNote, object: nil) }
                    .keyboardShortcut("n")
            }
        }
    }
}

extension Notification.Name {
    static let ionotesNewNote = Notification.Name("ionotesNewNote")
}

/// Opens and closes the main window. It is created once and kept (closing only hides it), so a click on the
/// menu bar icon or the Dock always brings the same window back.
@MainActor
enum Router {
    static var openSettings: OpenSettingsAction?
    private static var window: NSWindow?
    private static let windowDelegate = MainWindowDelegate()

    static func showMain() {
        NSApp.setActivationPolicy(.regular)  // a Dock icon while the window is open
        let window = self.window ?? makeWindow()
        self.window = window
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()  // in front even if macOS doesn't hand ionotes the focus
        Log.app.info("showMain: window visible=\(window.isVisible) key=\(window.isKeyWindow) active=\(NSApp.isActive)")
    }

    static func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let openSettings {
            openSettings()
        } else if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }),
                  let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    private static func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: MainWindow().environmentObject(NotesStore.shared))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.appearance = NSApp.appearance
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.center()
        window.setFrameAutosaveName("ionotes main window")
        window.delegate = windowDelegate
        return window
    }
}

/// Back to menu bar only (no Dock icon) once the window is closed.
private final class MainWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
