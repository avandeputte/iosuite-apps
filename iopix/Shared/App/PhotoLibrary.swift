import Foundation
import Photos

/// Reading originals out of the Photos library (downloading them from iCloud when only a preview is stored here).
enum PhotoLibrary {
    struct Gone: LocalizedError {
        var errorDescription: String? { "No longer in your Photos library" }
    }

    /// The original photo or video of an asset; edits made in Photos are not part of it.
    static func resource(for asset: PHAsset) -> PHAssetResource? {
        let all = PHAssetResource.assetResources(for: asset)
        let wanted: [PHAssetResourceType] = asset.mediaType == .video ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto]
        for type in wanted {
            if let r = all.first(where: { $0.type == type }) { return r }
        }
        return all.first
    }

    static func name(of asset: PHAsset) -> String {
        resource(for: asset)?.originalFilename ?? (asset.mediaType == .video ? "Video.mov" : "Photo.jpg")
    }

    /// Writes the original to a new temporary folder and returns the file.
    static func export(_ localID: String) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject,
              let res = resource(for: asset) else { throw Gone() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(res.originalFilename)
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: res, toFile: out, options: opts) { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
        return out
    }
}

/// Watches the Photos library and queues every photo or video added to it after watching was turned on.
/// Photos that were already in the library then are left alone (iopix skips duplicates anyway).
@MainActor
final class PhotosWatcher: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotosWatcher()

    @Published private(set) var enabled: Bool
    @Published private(set) var note: String?
    @Published private(set) var lastCheck: Date?

    private var known: Set<String> = []
    private var registered = false
    private var pending: Task<Void, Never>?
    private let knownFile = AppConfig.dataFolder.appendingPathComponent("seen-photos.json")

    override init() {
        enabled = AppConfig.defaults.bool(forKey: "watchPhotos")
        super.init()
        if enabled { start() }
    }

    var authorized: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    func setEnabled(_ on: Bool) async {
        note = nil
        guard on else {
            enabled = false
            AppConfig.defaults.set(false, forKey: "watchPhotos")
            return
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            #if os(macOS)
            note = "iopix may not see your photos. Allow it in System Settings › Privacy & Security › Photos."
            #else
            note = "iopix may not see your photos. Allow it in Settings › iopix › Photos."
            #endif
            enabled = false
            return
        }
        // what is in the library today counts as seen; only what comes after is sent
        // (a list kept from an earlier time watching is reused, so photos added in between are sent too)
        if !FileManager.default.fileExists(atPath: knownFile.path) {
            known = Set(allAssets().map(\.localIdentifier))
            saveKnown()
        }
        enabled = true
        AppConfig.defaults.set(true, forKey: "watchPhotos")
        start()
    }

    /// Queues the photos and videos taken in the last few days, whether or not they were seen before.
    func sendRecent(days: Int) {
        guard authorized else { return }
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        let recent = allAssets().filter { ($0.creationDate ?? .distantPast) >= since }
        UploadQueue.shared.add(assets: recent.map { (id: $0.localIdentifier, name: PhotoLibrary.name(of: $0)) })
    }

    private func start() {
        if known.isEmpty, let data = try? Data(contentsOf: knownFile), let ids = try? JSONDecoder().decode([String].self, from: data) {
            known = Set(ids)
        }
        if !registered && authorized {
            PHPhotoLibrary.shared().register(self)
            registered = true
        }
        schedule(after: 0)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.schedule(after: 3) }  // an import arrives as many changes in a row
    }

    private func schedule(after seconds: Double) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { checkNow() }
        }
    }

    func checkNow() {
        guard enabled, authorized else { return }
        let fresh = allAssets().filter { !known.contains($0.localIdentifier) }
        lastCheck = Date()
        guard !fresh.isEmpty else { return }
        for a in fresh { known.insert(a.localIdentifier) }
        saveKnown()
        UploadQueue.shared.add(assets: fresh.map { (id: $0.localIdentifier, name: PhotoLibrary.name(of: $0)) })
    }

    private func allAssets() -> [PHAsset] {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: opts)
        var out: [PHAsset] = []
        out.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    private func saveKnown() {
        if let data = try? JSONEncoder().encode(Array(known)) { try? data.write(to: knownFile, options: .atomic) }
    }
}
