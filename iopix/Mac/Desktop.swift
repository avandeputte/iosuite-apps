import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers
import WidgetKit

/// Desktop picture, screen saver folder, widget pictures, offline folders and Spotlight, kept up to date in the
/// background while the app runs.
@MainActor
final class DesktopExtras: ObservableObject {
    static let shared = DesktopExtras()
    @Published var offline: [OfflineSet] = OfflineSet.load()
    @Published var status: String?

    static let screenSaverFolder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iopix Screen Saver", isDirectory: true)
    static let offlineFolder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iopix Offline", isDirectory: true)
    private let wallpaperFolder = AppConfig.dataFolder.appendingPathComponent("Wallpaper", isDirectory: true)
    private var widgetFolder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.macGroup)?.appendingPathComponent("Widget", isDirectory: true)
    }
    private var timer: Task<Void, Never>?

    func start() {
        timer = Task {
            var round = 0
            while !Task.isCancelled {
                if (try? await IopixClient.shared.account())?.signedIn == true {
                    if round % max(MacPrefs.shared.wallpaperHours * 6, 1) == 0 { await changeWallpaper() }
                    if round % 18 == 0 { await refreshWidget() }       // every 3 hours
                    if round % 36 == 0 { await refreshScreenSaver(); await syncOffline(); await indexSpotlight() }  // every 6 hours
                }
                round += 1
                try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
            }
        }
    }

    // MARK: desktop picture

    func changeWallpaper() async {
        let p = MacPrefs.shared
        guard p.wallpaper != .off, let id = await PhotoSource.ids(p.wallpaper, person: p.wallpaperPerson, max: 20).first else { return }
        try? FileManager.default.removeItem(at: wallpaperFolder)
        guard let file = await PhotoSource.download(id, to: wallpaperFolder) else { return }
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true])
        }
    }

    // MARK: screen saver

    /// Up to 100 photos in Pictures › iopix Screen Saver, for macOS's own photo screen saver to show.
    func refreshScreenSaver() async {
        let p = MacPrefs.shared
        guard p.screenSaver != .off else { return }
        let ids = await PhotoSource.ids(p.screenSaver, person: p.screenSaverPerson, max: 100)
        guard !ids.isEmpty else { return }
        let folder = Self.screenSaverFolder
        let keep = Set(ids.map { "\($0).jpg" })
        for old in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(old) && old.hasSuffix(".jpg") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
        for id in ids where !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(id).jpg").path) {
            _ = await PhotoSource.download(id, to: folder)
        }
    }

    // MARK: widget

    /// The widget shows pictures the app leaves in the shared folder (the widget cannot sign in to iopix).
    func refreshWidget() async {
        guard let folder = widgetFolder else { return }
        var title = "On this day"
        var ids = await PhotoSource.ids(.onThisDay, max: 12)
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        let check = try? await IopixClient.shared.json("api/photos", query: [URLQueryItem(name: "md", value: String(format: "%02d-%02d", c.month ?? 1, c.day ?? 1))])
        if (check?["count"] as? NSNumber)?.intValue ?? 0 == 0 { title = "Rediscover"; ids = await PhotoSource.ids(.random, max: 12) }
        guard !ids.isEmpty else { return }
        let tmp = folder.deletingLastPathComponent().appendingPathComponent("Widget-new", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        var entries: [[String: Any]] = []
        for id in ids {
            guard let f = await PhotoSource.download(id, to: tmp) else { continue }
            var year = ""
            if let info = try? await IopixClient.shared.json("api/photo/\(id)"), let taken = info["taken"] as? String { year = String(taken.prefix(4)) }
            entries.append(["id": id, "file": f.lastPathComponent, "title": title, "year": year])
        }
        guard !entries.isEmpty, let data = try? JSONSerialization.data(withJSONObject: entries) else { return }
        try? data.write(to: tmp.appendingPathComponent("photos.json"))
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.moveItem(at: tmp, to: folder)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: offline folders

    struct OfflineSet: Codable, Identifiable, Hashable {
        enum Kind: String, Codable { case favorites, album, person }
        var kind: Kind
        var id: Int
        var name: String
        var key: String { "\(kind.rawValue)-\(id)" }

        var query: [URLQueryItem] {
            switch kind {
            case .favorites: return [URLQueryItem(name: "fav", value: "1")]
            case .album: return [URLQueryItem(name: "ualbum", value: String(id))]
            case .person: return [URLQueryItem(name: "tag", value: String(id))]
            }
        }

        static func load() -> [OfflineSet] {
            guard let data = UserDefaults.standard.data(forKey: "mac.offline") else { return [] }
            return (try? JSONDecoder().decode([OfflineSet].self, from: data)) ?? []
        }
    }

    func addOffline(_ set: OfflineSet) {
        guard !offline.contains(where: { $0.key == set.key }) else { return }
        offline.append(set)
        UserDefaults.standard.set(try? JSONEncoder().encode(offline), forKey: "mac.offline")
        Task { await syncOffline() }
    }

    func removeOffline(_ set: OfflineSet) {
        offline.removeAll { $0.key == set.key }
        UserDefaults.standard.set(try? JSONEncoder().encode(offline), forKey: "mac.offline")
    }

    /// The originals of each set in Pictures › iopix Offline › <name>; photos taken out of the set are removed
    /// (only files this app put there, listed in a hidden manifest).
    func syncOffline() async {
        for set in offline {
            let folder = Self.offlineFolder.appendingPathComponent(set.name.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
            let manifestURL = folder.appendingPathComponent(".iopix-offline.json")
            var manifest = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))) ?? [:]  // id -> file name
            guard let list = try? await PhotoList.load(set.query) else { continue }
            let want = Set(list.map(String.init))
            for (id, file) in manifest where !want.contains(id) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
                manifest.removeValue(forKey: id)
            }
            var fetched = 0
            for id in list where manifest[String(id)] == nil {
                status = "Downloading \(set.name)… \(fetched + 1) of \(list.count - manifest.count + fetched)"
                if let f = await PhotoSource.download(id, to: folder, original: true) {
                    manifest[String(id)] = f.lastPathComponent
                    fetched += 1
                }
                if fetched % 20 == 0, let data = try? JSONEncoder().encode(manifest) { try? data.write(to: manifestURL) }
            }
            if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: manifestURL) }
        }
        status = nil
    }

    // MARK: Spotlight

    /// People, folders, places and albums of iopix in Spotlight; picking one opens it in the iopix window.
    func indexSpotlight() async {
        guard let meta = try? await IopixClient.shared.json("api/meta") else { return }
        var items: [CSSearchableItem] = []
        func add(_ route: String, _ title: String, _ kind: String, _ count: Int?) {
            let a = CSSearchableItemAttributeSet(contentType: .content)
            a.title = title
            a.contentDescription = [kind, count.map { "\($0) photos" }].compactMap { $0 }.joined(separator: " · ")
            a.keywords = ["iopix", "photos", kind]
            items.append(CSSearchableItem(uniqueIdentifier: route, domainIdentifier: "iopix", attributeSet: a))
        }
        for t in meta["tags"] as? [[String: Any]] ?? [] {
            guard let id = (t["id"] as? NSNumber)?.intValue, let name = t["name"] as? String, let n = (t["n"] as? NSNumber)?.intValue, n > 0 else { continue }
            add("#/photos?tag=\(id)", name, (t["person"] as? NSNumber)?.boolValue == true ? "Person in iopix" : "Tag in iopix", n)
        }
        for a in meta["albums"] as? [[String: Any]] ?? [] {
            guard let id = (a["id"] as? NSNumber)?.intValue, let name = a["name"] as? String, let n = (a["nAll"] as? NSNumber)?.intValue, n > 0 else { continue }
            add("#/photos?album=\(id)", name, "Folder in iopix", n)
        }
        for p in meta["places"] as? [[Any]] ?? [] {
            guard p.count >= 4, let name = p[0] as? String, let n = (p[3] as? NSNumber)?.intValue else { continue }
            var q = URLComponents(); q.queryItems = [URLQueryItem(name: "place", value: name)]
            add("#/photos?\(q.percentEncodedQuery ?? "")", name, "Place in iopix", n)
        }
        if let st = try? await IopixClient.shared.json("api/state") {
            for a in st["albums"] as? [[String: Any]] ?? [] {
                guard let id = (a["id"] as? NSNumber)?.intValue, let name = a["name"] as? String else { continue }
                add("#/photos?ualbum=\(id)", name, "Album in iopix", (a["n"] as? NSNumber)?.intValue)
            }
        }
        let index = CSSearchableIndex.default()
        try? await index.deleteSearchableItems(withDomainIdentifiers: ["iopix"])
        try? await index.indexSearchableItems(items)
    }
}

/// A list of photo ids from iopix.
enum PhotoList {
    static func load(_ query: [URLQueryItem]) async throws -> [Int] {
        let j = try await IopixClient.shared.json("api/photos", query: query)
        return (j["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
    }
}
