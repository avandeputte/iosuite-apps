#if targetEnvironment(macCatalyst)
import SwiftUI
import CoreSpotlight
import UniformTypeIdentifiers
import WidgetKit
import ImageIO
import os

/// Desktop picture, screen saver folder, widget pictures, offline folders and Spotlight, kept up to date in the
/// background while the app runs (as the separate Mac app does).
@MainActor
final class MacDesktopExtras: ObservableObject {
    static let shared = MacDesktopExtras()
    @Published var offline: [OfflineSet] = OfflineSet.load()
    @Published var status: String?

    static let screenSaverFolder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iopix Screen Saver", isDirectory: true)
    static let offlineFolder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iopix Offline", isDirectory: true)
    private let wallpaperFolder = AppConfig.dataFolder.appendingPathComponent("Wallpaper", isDirectory: true)
    private let log = Logger(subsystem: "net.iothing.iopix", category: "extras")
    private var timer: Task<Void, Never>?

    func start() {
        timer = Task {
            while !Task.isCancelled {
                let account = try? await IopixClient.shared.account()
                guard account?.signedIn == true else {  // not signed in yet (or iopix out of reach): try again soon
                    try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                    continue
                }
                // each job remembers when it last ran, so a relaunch does not redo everything at once
                if due("wallpaper", hours: Double(MacPrefs.shared.wallpaperHours)) { await changeWallpaper(); ran("wallpaper") }
                if due("widget", hours: 0.5) { await refreshWidget(); ran("widget") }
                if due("screensaver", hours: 6) { await refreshScreenSaver(); ran("screensaver") }
                if due("offline", hours: 6) { await syncOffline(); ran("offline") }
                if due("spotlight", hours: 24) { await indexSpotlight(); ran("spotlight") }
                try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
            }
        }
    }

    private func due(_ job: String, hours: Double) -> Bool {
        let last = UserDefaults.standard.double(forKey: "mac.ran.\(job)")
        return Date().timeIntervalSince1970 - last >= hours * 3600 - 60
    }

    private func ran(_ job: String) { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "mac.ran.\(job)") }

    // MARK: desktop picture

    /// The new picture is fetched first and the old one removed only once the desktop shows the new one.
    func changeWallpaper() async {
        let p = MacPrefs.shared
        guard p.wallpaper != .off, let id = await MacPhotoSource.ids(p.wallpaper, person: p.wallpaperPerson, max: 20).first,
              let file = await MacPhotoSource.download(id, to: wallpaperFolder) else { return }
        MacExtras.bridge?.setWallpaper(file.path)
        for old in (try? FileManager.default.contentsOfDirectory(at: wallpaperFolder, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent != file.lastPathComponent {
            try? FileManager.default.removeItem(at: old)
        }
    }

    // MARK: screen saver

    /// Up to 100 photos in Pictures › iopix Screen Saver, for macOS's own photo screen saver to show.
    func refreshScreenSaver() async {
        let p = MacPrefs.shared
        guard p.screenSaver != .off else { return }
        let ids = await MacPhotoSource.ids(p.screenSaver, person: p.screenSaverPerson, max: 100)
        guard !ids.isEmpty else { return }
        let folder = Self.screenSaverFolder
        // only files this app put there are ever removed (listed in a hidden manifest); a photo of the user's own stays
        let manifestURL = folder.appendingPathComponent(".iopix-screensaver.json")
        var mine = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: manifestURL))) ?? [])
        let keep = Set(ids.map { "\($0).jpg" })
        for old in mine where !keep.contains(old) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
            mine.remove(old)
        }
        for id in ids where !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(id).jpg").path) {
            if let f = await MacPhotoSource.download(id, to: folder) { mine.insert(f.lastPathComponent) }
        }
        if let data = try? JSONEncoder().encode(Array(mine)) { try? data.write(to: manifestURL, options: .atomic) }
    }

    // MARK: widget

    /// The widget shows pictures the app leaves in the shared folder: the album list (to pick from), and up to 24
    /// photos for each source a widget on this Mac shows.
    func refreshWidget() async {
        guard let folder = WidgetStore.folder else { log.error("widget: no App Group folder"); return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let st = try? await IopixClient.shared.json("api/state") {
            let albums: [[String: Any]] = (st["albums"] as? [[String: Any]] ?? []).compactMap { a in
                guard let id = (a["id"] as? NSNumber)?.intValue, let name = a["name"] as? String else { return nil }
                return ["id": id, "name": name]
            }
            if let data = try? JSONSerialization.data(withJSONObject: albums) { try? data.write(to: folder.appendingPathComponent("albums.json"), options: .atomic) }
        }
        let infos: [WidgetInfo] = await withCheckedContinuation { c in
            WidgetCenter.shared.getCurrentConfigurations { c.resume(returning: (try? $0.get()) ?? []) }
        }
        guard !infos.isEmpty else { return }  // no widget placed: nothing to prepare
        var keys: Set<String> = []
        for info in infos { keys.insert(info.widgetConfigurationIntent(of: SelectPhotos.self)?.source?.id ?? "random") }
        for key in keys { await prepareWidget(key, in: folder) }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func prepareWidget(_ key: String, in folder: URL) async {
        let client = IopixClient.shared
        var ids: [Int] = [], times: [Double] = []
        if key == "random" {
            if let j = try? await client.json("api/random", query: [URLQueryItem(name: "n", value: "24")]) {
                ids = (j["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
                times = (j["ts"] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
            }
        } else {
            let q = key == "favorites" ? URLQueryItem(name: "fav", value: "1") : URLQueryItem(name: "ualbum", value: String(key.dropFirst("album-".count)))
            if let j = try? await client.json("api/photos", query: [q, URLQueryItem(name: "type", value: "photo")]) {
                let all = (j["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
                let ts = (j["ts"] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
                let pick = Array(all.indices.shuffled().prefix(24))
                ids = pick.map { all[$0] }
                times = pick.map { $0 < ts.count ? ts[$0] : 0 }
            }
        }
        guard !ids.isEmpty else { return }
        let tmp = folder.appendingPathComponent(key + "-new", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var entries: [[String: Any]] = []
        for (i, id) in ids.enumerated() {
            guard let (data, resp) = try? await client.session.data(for: client.request("preview/\(id)")),
                  (resp as? HTTPURLResponse)?.statusCode == 200, let small = Self.shrink(data, to: 640) else { continue }
            let file = tmp.appendingPathComponent("\(id).jpg")
            guard (try? small.write(to: file)) != nil else { continue }
            let year = i < times.count && times[i] > 0 ? String(Calendar.current.component(.year, from: Date(timeIntervalSince1970: times[i]))) : ""
            entries.append(["id": id, "file": file.lastPathComponent, "year": year])
        }
        guard !entries.isEmpty, let json = try? JSONSerialization.data(withJSONObject: entries) else { return }
        try? json.write(to: tmp.appendingPathComponent("photos.json"), options: .atomic)
        // swapped in one step, so a widget asking in between never finds the folder missing
        let dst = folder.appendingPathComponent(key, isDirectory: true)
        if FileManager.default.fileExists(atPath: dst.path) {
            _ = try? FileManager.default.replaceItemAt(dst, withItemAt: tmp, backupItemName: nil, options: [])
        } else {
            try? FileManager.default.moveItem(at: tmp, to: dst)
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    /// A smaller JPEG (widgets are a few hundred points wide).
    static func shrink(_ data: Data, to side: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: side,
                                                                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
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
            guard let list = try? await MacPhotoSource.list(set.query) else { continue }
            let want = Set(list.map(String.init))
            for (id, file) in manifest where !want.contains(id) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
                manifest.removeValue(forKey: id)
            }
            var fetched = 0
            for id in list where manifest[String(id)] == nil {
                status = "Downloading \(set.name)… \(fetched + 1) of \(list.count - manifest.count + fetched)"
                if let f = await MacPhotoSource.download(id, to: folder, original: true) {
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

    /// People, folders, places and albums of iopix in Spotlight; picking one opens it in the app.
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
            add("#/photos?tag=\(id)", name, (t["person"] as? NSNumber)?.boolValue == true ? "Person in ioPix" : "Tag in ioPix", n)
        }
        for a in meta["albums"] as? [[String: Any]] ?? [] {
            guard let id = (a["id"] as? NSNumber)?.intValue, let name = a["name"] as? String, let n = (a["nAll"] as? NSNumber)?.intValue, n > 0 else { continue }
            add("#/photos?album=\(id)", name, "Folder in ioPix", n)
        }
        for p in meta["places"] as? [[Any]] ?? [] {
            guard p.count >= 4, let name = p[0] as? String, let n = (p[3] as? NSNumber)?.intValue else { continue }
            var q = URLComponents(); q.queryItems = [URLQueryItem(name: "place", value: name)]
            add("#/photos?\(q.percentEncodedQuery ?? "")", name, "Place in ioPix", n)
        }
        if let st = try? await IopixClient.shared.json("api/state") {
            for a in st["albums"] as? [[String: Any]] ?? [] {
                guard let id = (a["id"] as? NSNumber)?.intValue, let name = a["name"] as? String else { continue }
                add("#/photos?ualbum=\(id)", name, "Album in ioPix", (a["n"] as? NSNumber)?.intValue)
            }
        }
        let index = CSSearchableIndex.default()
        try? await index.deleteSearchableItems(withDomainIdentifiers: ["iopix"])
        try? await index.indexSearchableItems(items)
    }
}
#endif
