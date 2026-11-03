import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: NotesStore
    @AppStorage(Prefs.clipboardEnabled) private var clipboardEnabled = true
    @AppStorage(Prefs.appearance) private var appearance = "system"
    @AppStorage(Prefs.inboxLimit) private var inboxLimit = 500
    @AppStorage(Prefs.skipPasswordLikeText) private var skipPasswordLike = true
    @AppStorage(Prefs.screenshotsEnabled) private var screenshotsEnabled = true
    @AppStorage(Prefs.autoSaveScreenshots) private var autoSaveScreenshots = false
    @State private var openAtLogin = LoginItem.status == .enabled

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Clipboard") {
                Toggle("Keep what I copy in the Inbox", isOn: $clipboardEnabled)
                Picker("Inbox keeps the last", selection: $inboxLimit) {
                    ForEach([100, 250, 500, 1000, 5000], id: \.self) { Text("\($0) items").tag($0) }
                }
                Text("The Inbox stays on this Mac; only notes go to the server.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Skip copied text that looks like a password", isOn: $skipPasswordLike)
                    .help("A single word of 10 to 64 characters mixing letters, digits and symbols. Catches password managers in the browser, like Proton Pass.")
                IgnoredAppsList()
            } header: {
                Text("Passwords")
            } footer: {
                Text("Copies made while one of these apps is in front never land in the Inbox, and neither do copies that apps mark as private. Password managers in the browser, like Proton Pass, are caught by the first option.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Screenshots") {
                Toggle("Watch for new screenshots", isOn: $screenshotsEnabled)
                Toggle("Save screenshots as notes right away", isOn: $autoSaveScreenshots)
                    .disabled(!screenshotsEnabled)
                LabeledContent("Screenshot folder") {
                    Text(ScreenshotWatcher.screenshotFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .foregroundStyle(.secondary)
                }
                Text("Text in screenshots is read on this Mac, so you can search for it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Right-click") {
                Text("Select text in any app, right-click, and choose Save to ionotes (it may be under Services). If it's missing, turn it on in System Settings › Keyboard › Keyboard Shortcuts › Services › Text, where you can also give it a shortcut.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Keyboard Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            }

            ServerSettings()

            Section("Login") {
                Toggle("Start in the menu bar when I log in", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            try LoginItem.setEnabled(on)
                        } catch {
                            store.lastError = error.localizedDescription
                        }
                        openAtLogin = LoginItem.status == .enabled
                    }
                if LoginItem.status == .requiresApproval {
                    Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
