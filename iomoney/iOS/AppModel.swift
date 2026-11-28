import LocalAuthentication
import SwiftUI

/// The signed-in account and what is around every screen. Nothing of the money is kept on the device.
@MainActor
final class AppModel: ObservableObject {
    @Published var credential: DeviceCredential?
    @Published var summary: Summary?
    @Published var accounts: [MoneyAccount] = []
    @Published var categories: [Category] = []
    @Published var problem: String?
    @Published var showSettings = false
    /// Covered until the person shows it is them (Face ID, Touch ID or the device's passcode).
    @Published var locked = false
    @Published var lockOn: Bool {
        didSet { UserDefaults.standard.set(lockOn, forKey: "lock") }
    }
    /// Counts up when something changed that other screens show (a transaction's category, one looked at).
    @Published var changes = 0

    private var unlocking = false

    init() {
        lockOn = UserDefaults.standard.object(forKey: "lock") as? Bool ?? true
        credential = Account.load()
        // a receipt that was opened is a file for as long as it is looked at: none stays from the last time
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("receipts"))
        locked = credential != nil && lockOn && AppModel.canLock
    }

    var api: API? { credential.map(API.init(credential:)) }
    var currency: String { summary?.currency ?? "USD" }

    func failed(_ error: Error, quiet: Bool = false) {
        if case APIError.signedOut = error {
            forget()
            problem = error.localizedDescription
        } else if !quiet {
            problem = error.localizedDescription
        }
    }

    func signedIn(_ c: DeviceCredential) async {
        credential = c
        await refresh(quiet: false)
    }

    /// The summary and the accounts, as the server has them now.
    func refresh(quiet: Bool = true) async {
        guard let api else { return }
        do {
            async let s = api.summary()
            async let a = api.accounts()
            (summary, accounts) = try await (s, a)
            if let c = try? await api.categories() { categories = c }
        } catch {
            failed(error, quiet: quiet)
        }
    }

    func signOut() {
        if let c = credential { Task { await DeviceSignIn.signOut(c) } }
        forget()
    }

    private func forget() {
        Account.clear()
        credential = nil
        summary = nil
        accounts = []
        categories = []
        locked = false
    }

    // MARK: the lock

    /// Whether the device has a way to tell it is its owner (a passcode, with or without Face ID or Touch ID).
    static var canLock: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }

    /// The app left the screen: covered again when it comes back.
    func leftScreen() {
        if credential != nil, lockOn, AppModel.canLock { locked = true }
    }

    func unlock() {
        guard locked, !unlocking else { return }
        unlocking = true
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Show your accounts") { ok, _ in
            Task { @MainActor in
                self.unlocking = false
                if ok { self.locked = false }
            }
        }
    }
}
