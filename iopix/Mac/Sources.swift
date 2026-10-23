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
    private let seenFile = AppConfig.dataFolder.appendingPathComponent("seen-files.json")
    private var timer: Task<Void, Never>?

    func start() {
        if let data = try? Data(contentsOf: seenFile), let list = try? JSONDecoder().decode([String].self, from: data) { seen = Set(list) }
        timer = Task {
            while !Task.isCancelled {
                scan()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !folders.contains(path) else { return }
        for f in files(in: path) { seen.insert(f.path) }
        folders.append(path)
        save()
    }

    func remove(_ path: String) {
        folders.removeAll { $0 == path }
        save()
    }

    private func scan() {
        var fresh: [URL] = []
        for folder in folders {
            for f in files(in: folder) where !seen.contains(f.path) {
                // still being copied in? wait for the next round
                if let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(m) < 5 { continue }
                seen.insert(f.path)
                fresh.append(f)
            }
        }
        guard !fresh.isEmpty else { return }
        UploadQueue.shared.add(files: fresh, review: true)
        save()
    }

    private func files(in folder: String) -> [URL] {
        let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.contentModificationDateKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var out: [URL] = []
        while let f = walker?.nextObject() as? URL, out.count < 50_000 { if isMedia(f) { out.append(f) } }
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
            Task { @MainActor in self.look(at: url) }
        }
    }

    func look(at volume: URL) {
        let dcim = volume.appendingPathComponent("DCIM")
        guard FileManager.default.fileExists(atPath: dcim.path) else { return }
        let walker = FileManager.default.enumerator(at: dcim, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        var files: [URL] = []
        while let f = walker?.nextObject() as? URL { if isMedia(f) { files.append(f) } }
        guard !files.isEmpty else { return }
        files.sort { $0.path < $1.path }
        let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? volume.lastPathComponent
        let new = Set(files.filter { !imported.contains(key(name, $0)) })
        offer = CardOffer(name: name, files: files, new: new)
        Notifier.post("card", title: "Photos on \(name)",
                      body: new.isEmpty ? "\(files.count) photos and videos, all imported before." : "\(new.count) new photos and videos. Click to import them to iopix.",
                      open: "card")
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
                    Text("iopix skips photos it already has.").font(.caption).foregroundStyle(.secondary)
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

    @MainActor
    static func collect() {
        guard let folder, let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for dir in items {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if !files.isEmpty { UploadQueue.shared.add(files: files, move: true) }
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
