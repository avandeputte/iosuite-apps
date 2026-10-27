#if targetEnvironment(macCatalyst)
import SwiftUI
import Combine
import UserNotifications
import UniformTypeIdentifiers

/// The Mac-only extras of the app (what the separate Mac app does): the Dock icon, notifications, watched folders,
/// memory cards, the desktop picture, screen saver, offline folders, Spotlight and the widget. The AppKit parts go
/// through the plug-in (MacMenuBar.shared.bar).
@MainActor
enum MacExtras {
    static var bridge: IopixStatusBarProtocol? { MacMenuBar.shared.bar }

    /// Called once at launch, after the menu bar icon is up.
    static func start() {
        MacDock.shared.start()
        MacNotifier.shared.start()
        MacFolderWatcher.shared.start()
        MacCardWatcher.shared.start()
        MacDesktopExtras.shared.start()
        bridge?.offerServices { paths in
            Task { @MainActor in UploadQueue.shared.add(files: paths.flatMap { expandMedia(URL(fileURLWithPath: $0)) }) }
        }
    }

    /// Opens a page of the library ("#/photos?md=10-23") in front.
    static func show(_ route: String) {
        Router.shared.open(route)
        bridge?.activate()
    }

    static func todayRoute() -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        return String(format: "#/photos?md=%02d-%02d", c.month ?? 1, c.day ?? 1)
    }
}

extension Notification.Name {
    /// Shows the memory card import sheet.
    static let iopixCards = Notification.Name("iopixCards")
}

/// A photo or video file, judged by its name (fast enough for a whole folder or card).
func isMediaFile(_ url: URL) -> Bool {
    guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
    return t.conforms(to: .image) || t.conforms(to: .movie)
}

/// A file as itself, a folder as the photos and videos in it.
func expandMedia(_ url: URL) -> [URL] {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [url] }
    let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    var out: [URL] = []
    while let f = walker?.nextObject() as? URL { if isMediaFile(f) { out.append(f) } }
    return out.sorted { $0.path < $1.path }
}

// MARK: - Settings

/// The Mac extras' settings (the same keys and defaults as the separate Mac app's).
@MainActor
final class MacPrefs: ObservableObject {
    static let shared = MacPrefs()
    private let d = UserDefaults.standard

    enum Source: String, CaseIterable, Identifiable {
        case off, onThisDay, favorites, random, person
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .onThisDay: return "On this day"
            case .favorites: return "Favorites"
            case .random: return "Rediscover (random)"
            case .person: return "A person"
            }
        }
    }

    @Published var notifyReview: Bool { didSet { d.set(notifyReview, forKey: "mac.notifyReview") } }
    @Published var notifyUploads: Bool { didSet { d.set(notifyUploads, forKey: "mac.notifyUploads") } }
    @Published var notifyOnThisDay: Bool { didSet { d.set(notifyOnThisDay, forKey: "mac.notifyOnThisDay") } }
    @Published var wallpaper: Source { didSet { d.set(wallpaper.rawValue, forKey: "mac.wallpaper") } }
    @Published var wallpaperPerson: Int { didSet { d.set(wallpaperPerson, forKey: "mac.wallpaperPerson") } }
    @Published var wallpaperHours: Int { didSet { d.set(wallpaperHours, forKey: "mac.wallpaperHours") } }
    @Published var screenSaver: Source { didSet { d.set(screenSaver.rawValue, forKey: "mac.screenSaver") } }
    @Published var screenSaverPerson: Int { didSet { d.set(screenSaverPerson, forKey: "mac.screenSaverPerson") } }

    init() {
        notifyReview = d.object(forKey: "mac.notifyReview") as? Bool ?? true
        notifyUploads = d.object(forKey: "mac.notifyUploads") as? Bool ?? true
        notifyOnThisDay = d.object(forKey: "mac.notifyOnThisDay") as? Bool ?? false
        wallpaper = Source(rawValue: d.string(forKey: "mac.wallpaper") ?? "") ?? .off
        wallpaperPerson = d.integer(forKey: "mac.wallpaperPerson")
        wallpaperHours = d.object(forKey: "mac.wallpaperHours") as? Int ?? 1
        screenSaver = Source(rawValue: d.string(forKey: "mac.screenSaver") ?? "") ?? .off
        screenSaverPerson = d.integer(forKey: "mac.screenSaverPerson")
    }
}

/// Photo ids for a source (On this day, favorites, random, a person), and downloading one.
enum MacPhotoSource {
    static func ids(_ source: MacPrefs.Source, person: Int = 0, max: Int = 60) async -> [Int] {
        let client = IopixClient.shared
        var q: [URLQueryItem] = [URLQueryItem(name: "type", value: "photo")]
        switch source {
        case .off: return []
        case .random:
            let j = try? await client.json("api/random", query: [URLQueryItem(name: "n", value: String(min(max, 60)))])
            return (j?["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        case .onThisDay:
            let c = Calendar.current.dateComponents([.month, .day], from: Date())
            q.append(URLQueryItem(name: "md", value: String(format: "%02d-%02d", c.month ?? 1, c.day ?? 1)))
        case .favorites:
            q.append(URLQueryItem(name: "fav", value: "1"))
        case .person:
            guard person > 0 else { return [] }
            q.append(URLQueryItem(name: "tag", value: String(person)))
        }
        let j = try? await client.json("api/photos", query: q)
        let all = (j?["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        if all.isEmpty && source == .onThisDay { return await ids(.random, max: max) }  // nothing on this date: random ones
        return Array(all.shuffled().prefix(max))
    }

    /// The photo ids of a list (all of them), for the offline folders.
    static func list(_ query: [URLQueryItem]) async throws -> [Int] {
        let j = try await IopixClient.shared.json("api/photos", query: query)
        return (j["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
    }

    /// Downloads a photo (the screen-size preview, or the original) to `folder`; returns the file.
    static func download(_ id: Int, to folder: URL, original: Bool = false) async -> URL? {
        let client = IopixClient.shared
        var req = client.request(original ? "orig/\(id)" : "preview/\(id)")
        if original, let u = req.url, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            c.queryItems = [URLQueryItem(name: "dl", value: "1")]  // the original's own file name comes with it
            req.url = c.url
        }
        guard let (data, resp) = try? await client.session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        var name = "\(id).jpg"
        if original, let cd = http.value(forHTTPHeaderField: "Content-Disposition") {
            if let r = cd.range(of: "filename*=UTF-8''") {
                name = String(cd[r.upperBound...].prefix { $0 != ";" }).removingPercentEncoding ?? name
            } else if let r = cd.range(of: "filename=\"") {
                name = String(cd[r.upperBound...].prefix { $0 != "\"" })
            }
            name = (name as NSString).lastPathComponent
            if name.isEmpty || name == "." || name == ".." { name = "\(id).jpg" }
            name = "\(id)-\(name)"  // two photos may share a file name
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }
}

// MARK: - Dock

/// The Dock icon shows how many photos are waiting, and a progress bar while they go.
@MainActor
final class MacDock {
    static let shared = MacDock()
    private var bag: Set<AnyCancellable> = []
    private var runTotal = 0

    func start() {
        UploadQueue.shared.$items
            .throttle(for: .milliseconds(300), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.update() }
            .store(in: &bag)
        update()
    }

    private func update() {
        let q = UploadQueue.shared
        let waiting = q.pending.count, review = q.reviewing.count
        let badge: String? = waiting > 0 ? "\(waiting)" : review > 0 ? "\(review) new" : nil
        var progress = -1.0
        if let current = q.current {
            runTotal = max(runTotal, waiting)
            let done = Double(runTotal - waiting) + current.progress
            progress = runTotal > 0 ? done / Double(runTotal) : current.progress
        } else {
            runTotal = 0
        }
        MacExtras.bridge?.dock(badge, progress: progress)
    }
}

// MARK: - Notifications

/// "5 new photos to look at", "Sent 12 photos to iopix", and, if wanted, a daily On this day.
@MainActor
final class MacNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacNotifier()
    private var bag: Set<AnyCancellable> = []
    private var lastReview = 0
    private var reviewTimer: Task<Void, Never>?

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self  // also set at launch (IopixApp), for a click that starts the app
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        lastReview = UploadQueue.shared.reviewing.count
        // $items fires before the change lands; a hop to the next run-loop turn sees the new list
        UploadQueue.shared.$items.receive(on: RunLoop.main).sink { [weak self] _ in self?.reviewChanged() }.store(in: &bag)
        NotificationCenter.default.publisher(for: .iopixUploadsDone).sink { note in
            guard MacPrefs.shared.notifyUploads, let n = note.userInfo?["count"] as? Int, n > 0 else { return }
            Self.post("uploads", title: "Sent to iopix", body: n == 1 ? "1 photo was added to iopix." : "\(n) photos were added to iopix.", open: "main")
        }.store(in: &bag)
        Task {
            while !Task.isCancelled {
                await onThisDay()
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
            }
        }
    }

    /// New photos waiting for review: one notification for a burst of them.
    private func reviewChanged() {
        let now = UploadQueue.shared.reviewing.count
        defer { lastReview = now }
        guard now > lastReview, MacPrefs.shared.notifyReview else { return }
        reviewTimer?.cancel()
        reviewTimer = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            let n = UploadQueue.shared.reviewing.count
            guard n > 0 else { return }
            Self.post("review", title: "New photos for iopix", body: n == 1 ? "1 new photo to look at." : "\(n) new photos to look at.", open: "review")
        }
    }

    /// Once a day, after 9 in the morning, when something was taken on this date in earlier years.
    private func onThisDay() async {
        guard MacPrefs.shared.notifyOnThisDay else { return }
        let c0 = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let today = String(format: "%04d-%02d-%02d", c0.year ?? 0, c0.month ?? 0, c0.day ?? 0)  // the local date, not UTC's
        guard UserDefaults.standard.string(forKey: "mac.otdNotified") != today,
              Calendar.current.component(.hour, from: Date()) >= 9 else { return }
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        guard let j = try? await IopixClient.shared.json("api/photos", query: [URLQueryItem(name: "md", value: String(format: "%02d-%02d", c.month ?? 1, c.day ?? 1))]),
              let n = (j["count"] as? NSNumber)?.intValue, n > 0 else { return }
        UserDefaults.standard.set(today, forKey: "mac.otdNotified")
        Self.post("otd", title: "On this day", body: n == 1 ? "1 photo from this date in earlier years." : "\(n) photos from this date in earlier years.", open: "otd")
    }

    static func post(_ id: String, title: String, body: String, open: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.userInfo = ["open": open]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let open = response.notification.request.content.userInfo["open"] as? String
        await MainActor.run {
            switch open {
            case "review": NotificationCenter.default.post(name: .iopixSendPhotos, object: nil)
            case "otd": MacExtras.show(MacExtras.todayRoute())
            case "card": NotificationCenter.default.post(name: .iopixCards, object: nil)
            default: break
            }
            MacExtras.bridge?.activate()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

// MARK: - Watched folders

/// Folders whose new photos and videos go to the review list, like the Photos library watcher. What is already in
/// a folder when it is added counts as seen.
@MainActor
final class MacFolderWatcher: ObservableObject {
    static let shared = MacFolderWatcher()
    @Published private(set) var folders: [String] = UserDefaults.standard.stringArray(forKey: "mac.watchFolders") ?? []
    private var seen: Set<String> = []
    private var sizes: [String: Int] = [:]  // files seen once but not yet settled: their size at the last scan
    private let seenFile = AppConfig.dataFolder.appendingPathComponent("seen-files.json")
    private var timer: Task<Void, Never>?

    func start() {
        if let data = try? Data(contentsOf: seenFile), let list = try? JSONDecoder().decode([String].self, from: data) { seen = Set(list) }
        timer = Task {
            while !Task.isCancelled {
                await scan()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    /// Asks for folders in an open panel.
    func pick() {
        MacExtras.bridge?.pickFolders("Photos and videos added to these folders from now on are listed for you to send to iopix") { paths in
            Task { @MainActor in for p in paths { MacFolderWatcher.shared.add(URL(fileURLWithPath: p)) } }
        }
    }

    func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !folders.contains(path) else { return }
        folders.append(path)
        Task {
            for f in await Self.files(in: path) { seen.insert(f.url.path) }
            save()
        }
    }

    func remove(_ path: String) {
        folders.removeAll { $0 == path }
        seen = seen.filter { !$0.hasPrefix(path + "/") }
        save()
    }

    /// Read off the main thread (a sleeping NAS must not freeze the app); a file counts as new once its size has
    /// stopped changing between two scans, so a copy still under way is left alone.
    private func scan() async {
        let folders = self.folders
        guard !folders.isEmpty else { return }
        let found = await Task.detached(priority: .utility) { () -> [(url: URL, size: Int)] in
            var out: [(URL, Int)] = []
            for folder in folders { out += await Self.files(in: folder) }
            return out
        }.value
        var fresh: [URL] = []
        var nextSizes: [String: Int] = [:]
        for f in found where !seen.contains(f.url.path) {
            if let last = sizes[f.url.path], last == f.size {
                seen.insert(f.url.path)
                fresh.append(f.url)
            } else {
                nextSizes[f.url.path] = f.size
            }
        }
        sizes = nextSizes
        let present = Set(found.map(\.url.path))
        let before = seen.count
        seen = seen.filter { present.contains($0) }
        guard !fresh.isEmpty || seen.count != before else { return }
        if !fresh.isEmpty { UploadQueue.shared.add(files: fresh, review: true) }
        save()
    }

    nonisolated private static func files(in folder: String) async -> [(url: URL, size: Int)] {
        let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.fileSizeKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var out: [(URL, Int)] = []
        while let f = walker?.nextObject() as? URL, out.count < 50_000 {
            if isMediaFile(f) { out.append((f, (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) }
        }
        return out
    }

    private func save() {
        UserDefaults.standard.set(folders, forKey: "mac.watchFolders")
        if let data = try? JSONEncoder().encode(Array(seen)) { try? data.write(to: seenFile, options: .atomic) }
    }
}

// MARK: - Cameras and memory cards

struct MacCardOffer: Identifiable {
    let id = UUID()
    let name: String
    let files: [URL]
    let new: Set<URL>  // not imported from this card before
}

/// A memory card, camera or USB drive with a DCIM folder: iopix offers to import its photos.
@MainActor
final class MacCardWatcher: ObservableObject {
    static let shared = MacCardWatcher()
    @Published var offer: MacCardOffer?
    private var imported: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "mac.cardImported") ?? [])

    func start() {
        MacExtras.bridge?.watchVolumes { path in
            Task { @MainActor in await MacCardWatcher.shared.look(at: URL(fileURLWithPath: path)) }
        }
        // a card that was already in when iopix started
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsRemovableKey], options: [.skipHiddenVolumes]) ?? [] {
            Task { await look(at: url) }
        }
    }

    /// Only local, removable drives with a DCIM folder; the card is read off the main thread.
    func look(at volume: URL) async {
        let v = try? volume.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeNameKey])
        guard v?.volumeIsLocal == true, (v?.volumeIsRemovable == true || v?.volumeIsEjectable == true) else { return }
        let files = await Task.detached(priority: .utility) { () -> [URL] in
            let dcim = volume.appendingPathComponent("DCIM")
            guard FileManager.default.fileExists(atPath: dcim.path) else { return [] }
            let walker = FileManager.default.enumerator(at: dcim, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            var files: [URL] = []
            while let f = walker?.nextObject() as? URL, files.count < 50_000 { if isMediaFile(f) { files.append(f) } }
            return files.sorted { $0.path < $1.path }
        }.value
        guard !files.isEmpty else { return }
        let name = v?.volumeName ?? volume.lastPathComponent
        let new = Set(files.filter { !imported.contains(key(name, $0)) })
        offer = MacCardOffer(name: name, files: files, new: new)
        guard !new.isEmpty else { return }  // nothing new: Import a card in Settings › Mac is there if wanted
        MacNotifier.post("card", title: "Photos on \(name)", body: "\(new.count) new photos and videos. Click to import them to iopix.", open: "card")
        NotificationCenter.default.post(name: .iopixCards, object: nil)
    }

    func importFiles(_ files: [URL], from name: String) {
        UploadQueue.shared.add(files: files)
        for f in files { imported.insert(key(name, f)) }
        UserDefaults.standard.set(Array(imported), forKey: "mac.cardImported")
        offer = nil
    }

    private func key(_ volume: String, _ f: URL) -> String {
        let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return "\(volume)|\(f.lastPathComponent)|\(size)"
    }
}

/// The photos on a memory card or camera, the new ones picked: import those you want.
struct MacCardImportSheet: View {
    @ObservedObject private var cards = MacCardWatcher.shared
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<URL> = []

    var body: some View {
        NavigationStack {
            Group {
                if let offer = cards.offer {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                            ForEach(offer.files, id: \.self) { f in
                                MacFileTile(url: f, picked: picked.contains(f), old: !offer.new.contains(f))
                                    .onTapGesture { if picked.contains(f) { picked.remove(f) } else { picked.insert(f) } }
                            }
                        }
                        .padding(6)
                    }
                    .safeAreaInset(edge: .top) {
                        HStack {
                            Text("\(offer.files.count) photos and videos on \(offer.name)").font(.headline)
                            Spacer()
                            Button("Pick new (\(offer.new.count))") { picked = offer.new }
                            Button(picked.count == offer.files.count ? "Pick none" : "Pick all") {
                                picked = picked.count == offer.files.count ? [] : Set(offer.files)
                            }
                        }
                        .padding(12).background(.bar)
                    }
                    .safeAreaInset(edge: .bottom) {
                        HStack {
                            Text("iopix skips photos it already has.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Import \(picked.count)") {
                                cards.importFiles(offer.files.filter { picked.contains($0) }, from: offer.name)
                                dismiss()
                            }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                            .disabled(picked.isEmpty)
                        }
                        .padding(12).background(.bar)
                    }
                    .onAppear { picked = offer.new }
                    .onChange(of: offer.id) { _, _ in picked = offer.new }
                } else {
                    ContentUnavailableView("No card", systemImage: "sdcard",
                                           description: Text("Insert a memory card or connect a camera and its photos show up here."))
                }
            }
            .navigationTitle("Import from a card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { cards.offer = nil; dismiss() } label: { BarText("Cancel") } } }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

private struct MacFileTile: View {
    let url: URL
    let picked: Bool
    let old: Bool
    @State private var image: Image?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay { if let image { image.resizable().scaledToFill() } }
            .clipped()
            .opacity(old && !picked ? 0.45 : 1)
            .overlay(alignment: .topTrailing) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(.white, picked ? Color.accentColor : Color.black.opacity(0.3)).padding(4)
            }
            .overlay { if picked { Rectangle().strokeBorder(Color.accentColor, lineWidth: 3) } }
            .help(url.lastPathComponent + (old ? " (imported before)" : ""))
            .task(id: url) { image = await AssetThumbnail.fileThumbnail(url) }
    }
}
#endif
