#if targetEnvironment(macCatalyst)
import SwiftUI

/// Settings › Mac: open at login, watched folders, cards, Finder, notifications, desktop picture, screen saver,
/// widget and offline folders (what the separate Mac app's settings have).
struct MacSettingsScreen: View {
    @ObservedObject private var prefs = MacPrefs.shared
    @ObservedObject private var folders = MacFolderWatcher.shared
    @ObservedObject private var extras = MacDesktopExtras.shared
    @State private var atLogin = MacExtras.bridge?.loginItem() ?? false
    @State private var loginNote: String?
    @State private var people: [(id: Int, name: String)] = []
    @State private var albums: [(id: Int, name: String)] = []
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $atLogin)
                    .onChange(of: atLogin) { _, on in
                        let why = MacExtras.bridge?.setLoginItem(on) ?? "Not available"
                        loginNote = why.isEmpty ? nil : why
                        if !why.isEmpty { atLogin = MacExtras.bridge?.loginItem() ?? false }
                    }
                if let loginNote { Text(loginNote).font(.caption).foregroundStyle(.orange) }
            } footer: {
                Text("Closing the window keeps iopix in the menu bar, still sending and watching.")
            }

            Section {
                ForEach(folders.folders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove", role: .destructive) { folders.remove(path) }
                    }
                }
                Button("Add a folder…") { folders.pick() }
            } header: {
                Text("Watched folders")
            } footer: {
                Text("New photos and videos in these folders (and the folders inside them) show up in New photos, like those from Photos.")
            }

            Section {
                Text("Insert a memory card or connect a camera that shows up as a drive: iopix lists its photos and offers to import the new ones.")
                Button("Import from a card…") { NotificationCenter.default.post(name: .iopixCards, object: nil) }
            } header: { Text("Cameras and memory cards") }

            Section {
                Text("Right-click photos or folders in Finder › Quick Actions or Services › Send to iopix Native. The Share button in Photos, Preview, Finder and Safari has iopix too.")
                Button("Turn on the Share menu entry…") { MacExtras.bridge?.openPath("x-apple.systempreferences:com.apple.ExtensionsPreferences?Sharing") }
            } header: { Text("Send to iopix") }

            Section("Notifications") {
                Toggle("New photos to look at", isOn: $prefs.notifyReview)
                Toggle("Photos sent to iopix", isOn: $prefs.notifyUploads)
                Toggle("On this day, once a day", isOn: $prefs.notifyOnThisDay)
            }

            Section {
                sourcePicker("Desktop picture", $prefs.wallpaper, person: $prefs.wallpaperPerson)
                if prefs.wallpaper != .off {
                    Picker("Change", selection: $prefs.wallpaperHours) {
                        Text("Every hour").tag(1); Text("Every 3 hours").tag(3); Text("Every day").tag(24)
                    }
                    Button(busy ? "Changing…" : "Change now") { run { await extras.changeWallpaper() } }.disabled(busy)
                }
            } header: { Text("Desktop picture") }

            Section {
                sourcePicker("Photos", $prefs.screenSaver, person: $prefs.screenSaverPerson)
                if prefs.screenSaver != .off {
                    Button(busy ? "Getting photos…" : "Get the photos now") { run { await extras.refreshScreenSaver() } }.disabled(busy)
                    Button("Open Screen Saver settings…") { MacExtras.bridge?.openPath("x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") }
                }
            } header: {
                Text("Screen saver")
            } footer: {
                Text("iopix keeps up to 100 photos in Pictures › iopix Screen Saver. In Screen Saver settings, pick a photo screen saver and choose that folder as its source.")
            }

            Section {
                Text("Right-click the desktop › Edit Widgets, and add iopix. It shows Rediscover, your favorites or an album.")
                Button(busy ? "Refreshing…" : "Refresh the widget now") { run { await extras.refreshWidget() } }.disabled(busy)
            } header: { Text("Widget") }

            Section {
                ForEach(extras.offline) { set in
                    HStack {
                        Image(systemName: set.kind == .favorites ? "heart" : set.kind == .album ? "rectangle.stack" : "person")
                        Text(set.name)
                        Spacer()
                        Button("Stop", role: .destructive) { extras.removeOffline(set) }
                    }
                }
                Menu("Keep offline…") {
                    Button("Favorites") { extras.addOffline(.init(kind: .favorites, id: 0, name: "Favorites")) }
                    if !albums.isEmpty {
                        Section("Albums") { ForEach(albums, id: \.id) { a in Button(a.name) { extras.addOffline(.init(kind: .album, id: a.id, name: a.name)) } } }
                    }
                    if !people.isEmpty {
                        Section("People") { ForEach(people, id: \.id) { p in Button(p.name) { extras.addOffline(.init(kind: .person, id: p.id, name: p.name)) } } }
                    }
                }
                if let status = extras.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: MacDesktopExtras.offlineFolder, withIntermediateDirectories: true)
                    MacExtras.bridge?.openPath(MacDesktopExtras.offlineFolder.path)
                }
                Button("Update now") { Task { await extras.syncOffline() } }
            } header: {
                Text("Offline folders")
            } footer: {
                Text("The originals are kept in Pictures › iopix Offline, one folder each, and kept up to date every few hours while iopix runs. Photos taken out of an album are removed from its folder.")
            }
        }
        .navigationTitle("Mac")
        .task { await loadLists() }
    }

    @ViewBuilder
    private func sourcePicker(_ title: String, _ source: Binding<MacPrefs.Source>, person: Binding<Int>) -> some View {
        Picker(title, selection: source) {
            ForEach(MacPrefs.Source.allCases) { Text($0.label).tag($0) }
        }
        if source.wrappedValue == .person {
            Picker("Person", selection: person) {
                Text("Choose…").tag(0)
                ForEach(people, id: \.id) { Text($0.name).tag($0.id) }
            }
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task { await work(); busy = false }
    }

    private func loadLists() async {
        if let meta = try? await IopixClient.shared.json("api/meta") {
            people = (meta["tags"] as? [[String: Any]] ?? []).compactMap { t in
                guard (t["person"] as? NSNumber)?.boolValue == true, let id = (t["id"] as? NSNumber)?.intValue,
                      let name = t["name"] as? String, ((t["n"] as? NSNumber)?.intValue ?? 0) > 0 else { return nil }
                return (id, name)
            }.sorted { $0.name < $1.name }
        }
        if let st = try? await IopixClient.shared.json("api/state") {
            albums = (st["albums"] as? [[String: Any]] ?? []).compactMap { a in
                guard let id = (a["id"] as? NSNumber)?.intValue, let n = a["name"] as? String else { return nil }
                return (id, n)
            }
        }
    }
}
#endif
