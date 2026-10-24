import Foundation
import Photos
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Shares send-or-ignore decisions between the person's Apple devices, so a new photo picked or ignored on one
/// leaves the review list on the others. All of them see the same iCloud Photos library, but each numbers the
/// photos its own way, so a decision is kept under the photo's iCloud identifier, in iCloud's key-value store
/// (one entry per device, so two devices never overwrite each other). Without iCloud Photos or an iCloud account
/// this does nothing and each device keeps its own list, as before.
@MainActor
final class ReviewSync: ObservableObject {
    static let shared = ReviewSync()

    /// What is kept in iCloud, for showing in settings.
    struct Summary: Equatable {
        var here = 0        // decided on this device
        var elsewhere = 0   // decided on the other devices
        var devices = 0     // how many devices have decided something
        var waiting = 0     // decided here, waiting for the photo to reach iCloud Photos
    }
    @Published private(set) var summary = Summary()

    private let kvs = NSUbiquitousKeyValueStore.default
    private static let prefix = "decided."
    private static let perDevice = 3000  // newest kept; about 200 KB, well inside iCloud's 1 MB
    private let device: String
    private var myKey: String { Self.prefix + device }
    /// Decided here, but iCloud has no identifier for the photo yet (not uploaded to iCloud Photos yet).
    private var pending: Set<String>
    private var observers: [NSObjectProtocol] = []
    private var running = false

    private init() {
        if let d = AppConfig.defaults.string(forKey: "reviewSync.device") {
            device = d
        } else {
            device = UUID().uuidString
            AppConfig.defaults.set(device, forKey: "reviewSync.device")
        }
        pending = Set(AppConfig.defaults.stringArray(forKey: "reviewSync.pending") ?? [])
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: kvs, queue: .main) { _ in
            Task { @MainActor in await ReviewSync.shared.apply(); ReviewSync.shared.refreshSummary() }
        })
        #if os(iOS)
        let active = UIApplication.didBecomeActiveNotification
        #else
        let active = NSApplication.didBecomeActiveNotification
        #endif
        observers.append(nc.addObserver(forName: active, object: nil, queue: .main) { _ in
            Task { @MainActor in ReviewSync.shared.kvs.synchronize(); await ReviewSync.shared.apply() }
        })
        kvs.synchronize()
        refreshSummary()
    }

    func refreshSummary() {
        var s = Summary(waiting: pending.count)
        for (key, value) in kvs.dictionaryRepresentation where key.hasPrefix(Self.prefix) {
            let n = (value as? [String: Any])?.count ?? 0
            guard n > 0 else { continue }
            s.devices += 1
            if key == myKey { s.here = n } else { s.elsewhere += n }
        }
        summary = s
    }

    /// Forgets every shared decision, from all devices. Photos already sent or ignored stay that way on each
    /// device; from now on only new decisions are shared.
    func reset() {
        for key in kvs.dictionaryRepresentation.keys where key.hasPrefix(Self.prefix) { kvs.removeObject(forKey: key) }
        kvs.synchronize()
        pending = []
        savePending()
        refreshSummary()
    }

    /// Looks for decisions made elsewhere now (and on every return to the app, and whenever iCloud brings some).
    func start() {
        Task { await apply() }
    }

    /// The person sent or ignored these photos here.
    func decided(localIDs: [String]) {
        guard !localIDs.isEmpty else { return }
        pending.formUnion(localIDs)
        savePending()
        Task { await flush() }
    }

    /// Takes photos decided on another device off this one's review list.
    func apply() async {
        guard !running else { return }
        running = true
        defer { running = false }
        await flush()
        let decided = allDecided()
        let review = UploadQueue.shared.reviewAssetIDs
        guard !decided.isEmpty, !review.isEmpty else { return }
        let map = await Self.cloudIDs(review)
        let gone = Set(map.filter { decided.contains($0.value) }.keys)
        if !gone.isEmpty { UploadQueue.shared.dropReview(localIDs: gone) }
    }

    /// Writes this device's decisions that now have an iCloud identifier.
    private func flush() async {
        guard !pending.isEmpty, Self.authorized else { return }
        let map = await Self.cloudIDs(Array(pending))
        guard !map.isEmpty else { return }
        var mine = (kvs.dictionary(forKey: myKey) as? [String: Double]) ?? [:]
        let now = Date().timeIntervalSince1970
        for (local, cloud) in map {
            mine[cloud] = now
            pending.remove(local)
        }
        if mine.count > Self.perDevice {
            mine = Dictionary(uniqueKeysWithValues: mine.sorted { $0.value > $1.value }.prefix(Self.perDevice).map { ($0.key, $0.value) })
        }
        kvs.set(mine, forKey: myKey)
        kvs.synchronize()
        savePending()
        refreshSummary()
    }

    /// Every photo decided on any of the devices (this one included).
    private func allDecided() -> Set<String> {
        var out = Set<String>()
        for (key, value) in kvs.dictionaryRepresentation where key.hasPrefix(Self.prefix) {
            if let d = value as? [String: Any] { out.formUnion(d.keys) }
        }
        return out
    }

    private func savePending() {
        // a photo that never reaches iCloud should not be retried forever
        if pending.count > 2000 { pending = Set(pending.prefix(2000)) }
        AppConfig.defaults.set(Array(pending), forKey: "reviewSync.pending")
    }

    private static var authorized: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    /// This device's photo ids to iCloud's; a photo without one yet is left out. Done off the main thread: the
    /// lookup can take a moment on a big library.
    private static func cloudIDs(_ locals: [String]) async -> [String: String] {
        guard authorized, !locals.isEmpty else { return [:] }
        return await Task.detached(priority: .utility) {
            var out: [String: String] = [:]
            for (local, result) in PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: locals) {
                if case .success(let cloud) = result { out[local] = cloud.stringValue }
            }
            return out
        }.value
    }
}
