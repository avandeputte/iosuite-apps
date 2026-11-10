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
    @AppStorage(Prefs.inboxMaxDays) private var inboxMaxDays = 0
    @AppStorage(Prefs.quickNoteHotKey) private var quickNoteHotKey = "ctrlOptN"
    @AppStorage(Prefs.formattedText) private var formattedText = true
    @State private var openAtLogin = LoginItem.status == .enabled

    var body: some View {
        // Tabs, each a scrolling form, so the window stays short enough for a laptop screen.
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            InboxRulesView().tabItem { Label("Inbox Rules", systemImage: "line.3.horizontal.decrease.circle") }
            passwords.tabItem { Label("Passwords", systemImage: "key") }
            Form { ServerSettings() }
                .formStyle(.grouped)
                .tabItem { Label("Server", systemImage: "server.rack") }
        }
        .frame(width: 540, height: 520)
    }

    private var general: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                Toggle("Show notes formatted (Markdown), with boxes to tick", isOn: $formattedText)
            }

            Section("Quick note") {
                Picker("Shortcut from any app", selection: $quickNoteHotKey) {
                    ForEach(HotKey.choices, id: \.0) { Text($0.1).tag($0.0) }
                }
                Text("Opens a small window to type a note in, from whatever app you're in. ⌘Return saves it. Also in the menu bar icon's right-click menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Clipboard") {
                Toggle("Keep what I copy in the Inbox", isOn: $clipboardEnabled)
                Picker("Inbox keeps the last", selection: $inboxLimit) {
                    ForEach([100, 250, 500, 1000, 5000], id: \.self) { Text("\($0) items").tag($0) }
                }
                Picker("Remove items older than", selection: $inboxMaxDays) {
                    Text("Never").tag(0)
                    ForEach([1, 7, 30, 90], id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                }
                Text("The Inbox stays on this Mac; only notes go to the server.")
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
    }

    private var passwords: some View {
        Form {
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
        }
        .formStyle(.grouped)
    }
}
