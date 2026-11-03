import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The apps whose copies never go into the Inbox (Prefs.ignoredApps).
enum IgnoredApps {
    static func add(_ bundleID: String) {
        var ids = Prefs.ignoredAppIDs
        guard !ids.contains(bundleID) else { return }
        ids.append(bundleID)
        Prefs.ignoredAppIDs = ids
    }

    static func remove(_ bundleID: String) {
        Prefs.ignoredAppIDs = Prefs.ignoredAppIDs.filter { $0 != bundleID }
    }

    /// The bundle id of a running app by its name, as the Inbox records it ("Proton Pass").
    static func bundleID(named name: String) -> String? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.bundleIdentifier
    }

    /// "Proton Pass", or the bundle id when the app isn't installed here.
    static func displayName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func icon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Choose an app in /Applications to add.
    @MainActor
    static func choose() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Never Keep Copies"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { add(id) }
        }
    }
}

/// Settings list: the installed apps on the list, with a minus button each and Add App….
struct IgnoredAppsList: View {
    @State private var ids = Prefs.ignoredAppIDs

    var body: some View {
        let installed = ids.filter(IgnoredApps.isInstalled)
        ForEach(installed, id: \.self) { id in
            HStack {
                if let icon = IgnoredApps.icon(id) {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                Text(IgnoredApps.displayName(id))
                Spacer()
                Button {
                    IgnoredApps.remove(id)
                    ids = Prefs.ignoredAppIDs
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Keep copies from this app again")
            }
        }
        if installed.isEmpty {
            Text("No password managers found on this Mac.").foregroundStyle(.secondary)
        }
        Button("Add App…") {
            IgnoredApps.choose()
            ids = Prefs.ignoredAppIDs
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let now = Prefs.ignoredAppIDs
            if now != ids { ids = now }
        }
    }
}
