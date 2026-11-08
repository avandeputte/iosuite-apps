import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A photo or video file, judged by its name (fast enough for a whole folder or card).
func isMedia(_ url: URL) -> Bool {
    guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
    return t.conforms(to: .image) || t.conforms(to: .movie)
}

// MARK: - Watched folders

/// Folders whose new photos and videos go to the review list, like the Photos library watcher. What is already in
/// a folder when it is added counts as seen.
@MainActor
final class FolderWatcher: ObservableObject {
    static let shared = FolderWatcher()
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

    /// The folders are read off the main thread (a sleeping NAS must not freeze the menu bar); a file counts as new
    /// once its size has stopped changing between two scans, so a copy still under way is left alone.
    private func scan() async {
        let folders = self.folders
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
        // files that went away (deleted or renamed) leave the seen list, so it does not grow forever
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
            if isMedia(f) { out.append((f, (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) }
        }
        return out
    }

    private func save() {
        UserDefaults.standard.set(folders, forKey: "mac.watchFolders")
        if let data = try? JSONEncoder().encode(Array(seen)) { try? data.write(to: seenFile, options: .atomic) }
    }
}

// MARK: - Cameras and memory cards

struct CardOffer: Identifiable {
    let id = UUID()
    let name: String
    let files: [URL]
    let new: Set<URL>  // not imported from this card before
}

/// A memory card, camera or USB drive with a DCIM folder: iopix offers to import its photos.
@MainActor
final class CardWatcher: ObservableObject {
    static let shared = CardWatcher()
    @Published var offer: CardOffer?
    private var imported: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "mac.cardImported") ?? [])

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in await self.look(at: url) }
        }
        // a card that was already in when iopix started
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsRemovableKey], options: [.skipHiddenVolumes]) ?? [] {
            Task { @MainActor in await self.look(at: url) }
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
            while let f = walker?.nextObject() as? URL, files.count < 50_000 { if isMedia(f) { files.append(f) } }
            return files.sorted { $0.path < $1.path }
        }.value
        guard !files.isEmpty else { return }
        let name = v?.volumeName ?? volume.lastPathComponent
        let new = Set(files.filter { !imported.contains(key(name, $0)) })
        offer = CardOffer(name: name, files: files, new: new)
        guard !new.isEmpty else { return }  // nothing new: the Import window is there from the menu if wanted
        Notifier.post("card", title: "Photos on \(name)", body: "\(new.count) new photos and videos. Click to import them to ioPix.", open: "card")
        Router.open("card")
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

struct CardImportView: View {
    @ObservedObject private var cards = CardWatcher.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var picked: Set<URL> = []

    var body: some View {
        VStack(spacing: 0) {
            if let offer = cards.offer {
                HStack {
                    Text("\(offer.files.count) photos and videos on \(offer.name)").font(.headline)
                    Spacer()
                    Button("Pick new (\(offer.new.count))") { picked = offer.new }
                    Button(picked.count == offer.files.count ? "Pick none" : "Pick all") {
                        picked = picked.count == offer.files.count ? [] : Set(offer.files)
                    }
                }
                .padding(12)
                Divider()
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                        ForEach(offer.files, id: \.self) { f in
                            FileTile(url: f, picked: picked.contains(f), old: !offer.new.contains(f))
                                .onTapGesture { if picked.contains(f) { picked.remove(f) } else { picked.insert(f) } }
                        }
                    }
                    .padding(6)
                }
                Divider()
                HStack {
                    Text("ioPix skips photos it already has.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { cards.offer = nil; dismissWindow(id: "card") }
                    Button("Import \(picked.count)") {
                        cards.importFiles(offer.files.filter { picked.contains($0) }, from: offer.name)
                        dismissWindow(id: "card")
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty)
                }
                .padding(12)
                .onAppear { picked = offer.new }
                .onChange(of: offer.id) { _, _ in picked = offer.new }
            } else {
                ContentUnavailableView("No card", systemImage: "sdcard",
                                       description: Text("Insert a memory card or connect a camera and its photos show up here."))
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

private struct FileTile: View {
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

// MARK: - Send to iopix (Finder right-click, Share menu)

/// Finder › right-click › Services (or Quick Actions) › Send to iopix.
final class ServiceProvider: NSObject {
    @objc func sendToIopix(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        Task { @MainActor in
            UploadQueue.shared.add(files: urls.flatMap(MenuView.expand))
        }
    }
}

/// The Share menu extension drops files in the shared App Group folder; the app takes them from there.
enum Inbox {
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.macGroup)?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Folders the Share extension has finished writing (it names them "<id>.tmp" while copying).
    @MainActor
    static func collect() {
        guard let folder, let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for dir in items where dir.pathExtension != "tmp" {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if !files.isEmpty { UploadQueue.shared.add(files: files, move: true) }
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
