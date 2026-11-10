import AppKit
import os

enum Log {
    static let app = Logger(subsystem: "net.iothing.ionotes", category: "app")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var store = NotesStore.shared
    private var clipboard: ClipboardMonitor?
    private var screenshots: ScreenshotWatcher?
    private var services: ServiceProvider?
    private var defaultsObserver: NSObjectProtocol?
    private var statusItem: StatusItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One ionotes at a time: registering the login item starts a copy straight away (RunAtLoad).
        let me = NSRunningApplication.current
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0 != me && ($0.launchDate ?? .distantPast) <= (me.launchDate ?? .distantFuture) }) {
            if !LoginItem.launchedInBackground { other.activate() }
            exit(0)
        }
        // Started at login: live in the menu bar only until the window is opened.
        if LoginItem.launchedInBackground { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.enableOnFirstRun()
        statusItem = StatusItem()
        // Right-click › Save to ionotes, in any app.
        let services = ServiceProvider(store: store)
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        self.services = services

        clipboard = ClipboardMonitor(store: store)
        screenshots = ScreenshotWatcher(store: store)
        applySettings()
        if !LoginItem.launchedInBackground { Router.showMain() }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store.syncSoon(after: 0)
    }

    /// Closing the window keeps ionotes running in the menu bar, watching the clipboard.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Set by the menu bar icon's Quit, the one way to really quit ionotes by hand.
    static var reallyQuit = false

    /// Quit from the Dock or ⌘Q closes the window and keeps ionotes in the menu bar; logout, restart and shutdown still quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue
        let systemQuit = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart,
                          kAEShowShutdownDialog, kAEShutDown].contains { $0 == reason }
        if Self.reallyQuit || systemQuit { return .terminateNow }
        Log.app.info("quit intercepted: closing the window, staying in the menu bar")
        // Only real windows: the menu bar icon lives in a window of its own, and closing that one
        // leaves the icon on screen but dead to clicks.
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) { window.close() }
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Router.showMain() }
        return true
    }

    private func applySettings() {
        switch UserDefaults.standard.string(forKey: Prefs.appearance) {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil  // follow the system
        }
        // The open Settings form doesn't pick up the app-level change by itself.
        for window in NSApp.windows { window.appearance = NSApp.appearance }
        HotKey.shared.apply()
        if Prefs.bool(Prefs.clipboardEnabled) { clipboard?.start() } else { clipboard?.stop() }
        if Prefs.bool(Prefs.screenshotsEnabled) {
            if screenshots?.isRunning == false { screenshots?.start() }
        } else {
            screenshots?.stop()
        }
    }
}
