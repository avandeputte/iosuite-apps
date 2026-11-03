import Foundation
import ServiceManagement

/// Starting at login, in the menu bar only. A launch agent (Mac/LaunchAgent, copied into the app at
/// Contents/Library/LaunchAgents) opens the app with `--background`, which skips the window and Dock icon.
enum LoginItem {
    private static let service = SMAppService.agent(plistName: "net.iothing.ionotes.login.plist")
    private static let configuredKey = "loginItemConfigured"

    static var launchedInBackground: Bool { CommandLine.arguments.contains("--background") }

    static var status: SMAppService.Status { service.status }

    static func setEnabled(_ on: Bool) throws {
        if on { try service.register() } else { try service.unregister() }
    }

    /// Turns starting at login on the first time ionotes runs; after that the Settings switch decides.
    static func enableOnFirstRun() {
        guard !UserDefaults.standard.bool(forKey: configuredKey) else { return }
        do {
            try service.register()
        } catch {
            NSLog("ionotes: could not add the login item: \(error)")
        }
        UserDefaults.standard.set(true, forKey: configuredKey)
    }
}
