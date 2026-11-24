import Foundation
import UIKit

/// The one place a sync runs from, whether the user tapped Sync now, the app was opened, HealthKit woke us in
/// the background, or iOS granted a background refresh. Only one sync runs at a time.
@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    enum State: Equatable { case idle, authorizing, syncing, done(Int), paused(Int), failed(String) }
    enum Trigger: String { case manual, launch, healthKit, backgroundRefresh }

    @Published var state: State = .idle
    @Published var currentType = ""
    @Published var sentCount = 0
    @Published var fullResync = false
    @Published private(set) var isRunning = false
    @Published var authorized = UserDefaults.standard.bool(forKey: "authorized")
    @Published var autoSync = UserDefaults.standard.object(forKey: "autoSync") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSync, forKey: "autoSync") }
    }
    /// This iPhone's sign-in (shared/DeviceSignIn): the address, the name and the app password the server made for it.
    /// nil until signed in, and again after signing out or once the server stopped taking the app password.
    @Published private(set) var credential: DeviceCredential? = SyncEngine.migratedCredential()
    @Published var showSignIn = false

    private static func migratedCredential() -> DeviceCredential? {
        let store = DeviceCredentialStore(app: .iohealth)
        let d = UserDefaults.standard
        if store.lastAddress == nil, let old = d.string(forKey: "serverAddress"), !old.isEmpty {
            store.remember(address: old, name: d.string(forKey: "userName") ?? "")  // fills the new sign-in screen
        }
        if d.object(forKey: "serverAddress") != nil {
            d.removeObject(forKey: "serverAddress")
            LegacyCredentials.remove()
        }
        return store.load()
    }

    func signedIn(_ c: DeviceCredential) {
        credential = c
        showSignIn = false
    }

    func signOut() async {
        guard let c = credential else { return }
        await DeviceSignIn.signOut(c)
        DeviceCredentialStore(app: .iohealth).forgetPassword()
        credential = nil
    }

    /// The server no longer takes the app password (removed in Settings › Account): sign in again, with the
    /// address and name filled in.
    func lostSignIn() {
        DeviceCredentialStore(app: .iohealth).forgetPassword()
        credential = nil
        showSignIn = true
    }

    @Published private(set) var lastSynced: Date? = UserDefaults.standard.object(forKey: "lastSynced") as? Date
    @Published private(set) var lastTrigger: Trigger? = UserDefaults.standard.string(forKey: "lastTrigger").flatMap(Trigger.init)
    @Published private(set) var lastBackgroundAttempt: Date?

    let reader = HealthReader()

    func authorize() async {
        state = .authorizing
        do {
            try await reader.requestAuthorization()
            authorized = true
            UserDefaults.standard.set(true, forKey: "authorized")
            state = .idle
            BackgroundSync.start(store: reader.store)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    var server: SyncClient.Server? { credential.map(SyncClient.Server.init) }

    /// Whether a sync has somewhere to go.
    var hasTarget: Bool { server != nil }

    func syncNow(trigger: Trigger, deadline: Date?) async {
        guard let server else { return }
        await run(server: server, trigger: trigger, deadline: deadline)
    }

    /// Called from HealthKit observer wakes and background refresh. Coalesces the burst of observer callbacks
    /// that arrive together, and keeps inside the ~30 s iOS gives a background wake.
    func backgroundSync(trigger: Trigger) async {
        guard autoSync, authorized, hasTarget, !isRunning else { return }
        if let last = lastBackgroundAttempt, Date().timeIntervalSince(last) < 10 * 60 { return }
        lastBackgroundAttempt = Date()
        // iOS calls the expiration handler on the main thread.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ioHealthSync") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        await syncNow(trigger: trigger, deadline: Date().addingTimeInterval(22))
        endBackgroundTask()
    }

    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func run(server: SyncClient.Server, trigger: Trigger, deadline: Date?) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        state = .syncing
        sentCount = 0
        currentType = ""
        reader.fullResync = fullResync
        let foreground = trigger == .manual || trigger == .launch
        if foreground { UIApplication.shared.isIdleTimerDisabled = true }
        defer { if foreground { UIApplication.shared.isIdleTimerDisabled = false } }

        do {
            let upload = try await SyncClient.Upload.start(server: server, hello: .init(
                protocolVersion: SyncProtocol.version, deviceName: UIDevice.current.name,
                systemVersion: UIDevice.current.systemVersion, fullResync: fullResync))
            reader.checkpoint = { try await upload.flush() }
            defer { reader.checkpoint = {} }
            var ranOutOfTime = false
            do {
                try await reader.readAll(progress: { [weak self] label in
                    Task { @MainActor in self?.currentType = label }
                }, emit: { [weak self] message in
                    if let deadline, Date() > deadline { throw SyncError.outOfTime }
                    // The server ignores per-type markers, and each would otherwise cost an upload at the next checkpoint.
                    if case .typeDone = message { return }
                    try await upload.send(message)
                    if upload.sent % 2_000 == 0 { let n = upload.sent; await MainActor.run { self?.sentCount = n } }
                })
            } catch SyncError.outOfTime {
                // Anchors only moved for batches the server committed, so the next run picks up from there.
                ranOutOfTime = true
            }
            let n = upload.sent
            _ = try await upload.finish(totalSent: n)
            sentCount = n
            fullResync = false
            remember(trigger: trigger)
            state = ranOutOfTime ? .paused(n) : .done(n)
        } catch SyncError.unauthorized {
            lostSignIn()
            state = .failed(SyncError.unauthorized.localizedDescription)
        } catch {
            state = .failed(error.localizedDescription)
        }
        BackgroundSync.scheduleRefresh()
    }

    private func remember(trigger: Trigger) {
        lastSynced = Date()
        lastTrigger = trigger
        UserDefaults.standard.set(lastSynced, forKey: "lastSynced")
        UserDefaults.standard.set(trigger.rawValue, forKey: "lastTrigger")
    }
}
