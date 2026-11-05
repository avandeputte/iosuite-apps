import SwiftUI
import AppKit

/// Settings › Sources: watched folders, cards, Finder and the Share menu, notifications.
struct SourcesSettings: View {
    @ObservedObject private var folders = FolderWatcher.shared
    @ObservedObject private var prefs = MacPrefs.shared

    var body: some View {
        Form {
            Section {
                ForEach(folders.folders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { folders.remove(path) }.buttonStyle(.link)
                    }
                }
                Button("Add a folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    panel.message = "Photos and videos added to these folders from now on are listed for you to send to ioPix"
                    NSApp.activate(ignoringOtherApps: true)
                    if panel.runModal() == .OK { panel.urls.forEach(folders.add) }
                }
            } header: {
                Text("Watched folders")
            } footer: {
                Text("New photos and videos in these folders (and the folders inside them) show up in New photos, like those from Photos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Insert a memory card or connect a camera that shows up as a drive: ioPix lists its photos and offers to import the new ones.")
                    .font(.callout)
            } header: { Text("Cameras and memory cards") }
            Section {
                Text("Right-click photos or folders in Finder › Quick Actions or Services › Send to ioPix. The Share button in Photos, Preview, Finder and Safari has ioPix too.")
                    .font(.callout)
                Button("Turn on the Share menu entry…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?Sharing")!)
                }
            } header: { Text("Send to ioPix") }
            Section("Notifications") {
                Toggle("New photos to look at", isOn: $prefs.notifyReview)
                Toggle("Photos sent to ioPix", isOn: $prefs.notifyUploads)
                Toggle("On this day, once a day", isOn: $prefs.notifyOnThisDay)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings › Desktop: desktop picture, screen saver, widget.
struct DesktopSettings: View {
    @ObservedObject private var prefs = MacPrefs.shared
    @State private var people: [(id: Int, name: String)] = []
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                sourcePicker("Desktop picture", $prefs.wallpaper, person: $prefs.wallpaperPerson)
                if prefs.wallpaper != .off {
                    Picker("Change", selection: $prefs.wallpaperHours) {
                        Text("Every hour").tag(1)
                        Text("Every 3 hours").tag(3)
                        Text("Every day").tag(24)
                    }
                    Button(busy ? "Changing…" : "Change now") { run { await DesktopExtras.shared.changeWallpaper() } }.disabled(busy)
                }
            } header: { Text("Desktop picture") }
            Section {
                sourcePicker("Photos", $prefs.screenSaver, person: $prefs.screenSaverPerson)
                if prefs.screenSaver != .off {
                    Button(busy ? "Getting photos…" : "Get the photos now") { run { await DesktopExtras.shared.refreshScreenSaver() } }.disabled(busy)
                    Button("Open Screen Saver settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension")!)
                    }
                }
            } header: {
                Text("Screen saver")
            } footer: {
                Text("ioPix keeps up to 100 photos in Pictures › iopix Screen Saver. In Screen Saver settings, pick a photo screen saver and choose that folder as its source.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Right-click the desktop › Edit Widgets, and add ioPix. It shows On this day, or Rediscover when nothing was taken on this date.")
                    .font(.callout)
                Button(busy ? "Refreshing…" : "Refresh the widget now") { run { await DesktopExtras.shared.refreshWidget() } }.disabled(busy)
            } header: { Text("Widget") }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task { await loadPeople() }
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

    private func loadPeople() async {
        guard let meta = try? await IopixClient.shared.json("api/meta") else { return }
        people = (meta["tags"] as? [[String: Any]] ?? []).compactMap { t in
            guard (t["person"] as? NSNumber)?.boolValue == true, let id = (t["id"] as? NSNumber)?.intValue,
                  let name = t["name"] as? String, ((t["n"] as? NSNumber)?.intValue ?? 0) > 0 else { return nil }
            return (id, name)
        }.sorted { $0.name < $1.name }
    }
}

/// Settings › Offline: favorites, albums or people kept as folders of originals on this Mac.
struct OfflineSettings: View {
    @ObservedObject private var extras = DesktopExtras.shared
    @State private var albums: [(id: Int, name: String)] = []
    @State private var people: [(id: Int, name: String)] = []

    var body: some View {
        Form {
            Section {
                ForEach(extras.offline) { set in
                    HStack {
                        Image(systemName: set.kind == .favorites ? "heart" : set.kind == .album ? "rectangle.stack" : "person")
                        Text(set.name)
                        Spacer()
                        Button("Stop") { extras.removeOffline(set) }.buttonStyle(.link)
                    }
                }
                Menu("Keep offline…") {
                    Button("Favorites") { extras.addOffline(.init(kind: .favorites, id: 0, name: "Favorites")) }
                    if !albums.isEmpty {
                        Section("Albums") {
                            ForEach(albums, id: \.id) { a in Button(a.name) { extras.addOffline(.init(kind: .album, id: a.id, name: a.name)) } }
                        }
                    }
                    if !people.isEmpty {
                        Section("People") {
                            ForEach(people, id: \.id) { p in Button(p.name) { extras.addOffline(.init(kind: .person, id: p.id, name: p.name)) } }
                        }
                    }
                }
                if let status = extras.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: DesktopExtras.offlineFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(DesktopExtras.offlineFolder)
                    }
                    Button("Update now") { Task { await extras.syncOffline() } }
                }
            } header: {
                Text("Offline folders")
            } footer: {
                Text("The originals are kept in Pictures › iopix Offline, one folder each, and kept up to date every few hours while ioPix runs. Photos taken out of an album are removed from its folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            if let st = try? await IopixClient.shared.json("api/state") {
                albums = (st["albums"] as? [[String: Any]] ?? []).compactMap { a in
                    guard let id = (a["id"] as? NSNumber)?.intValue, let n = a["name"] as? String else { return nil }
                    return (id, n)
                }
            }
            if let meta = try? await IopixClient.shared.json("api/meta") {
                people = (meta["tags"] as? [[String: Any]] ?? []).compactMap { t in
                    guard (t["person"] as? NSNumber)?.boolValue == true, let id = (t["id"] as? NSNumber)?.intValue,
                          let name = t["name"] as? String, ((t["n"] as? NSNumber)?.intValue ?? 0) > 0 else { return nil }
                    return (id, name)
                }.sorted { $0.name < $1.name }
            }
        }
    }
}
