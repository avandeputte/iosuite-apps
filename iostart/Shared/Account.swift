import Foundation
import Security

/// What the app and its share extension have in common: the app group they both read.
enum Shared {
    static let group = "group.net.iothing.iostart"
    static let keychainService = "net.iothing.iostart"

    static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }

    /// Where the last tree is kept, for an instant start and for the share extension's folder list.
    static var cacheFile: URL {
        let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("tree.json")
    }

    /// The last /dav/ext/today answer, for the widgets when the start page cannot be reached.
    static var todayFile: URL {
        let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("today.json")
    }

}

/// The one sign-in of the ioSuite apps (shared/DeviceSignIn), for the start page at the root of the address.
extension DeviceApp {
    static let iostart = DeviceApp(name: "ioStart", folder: "", keychainService: Shared.keychainService, accessGroup: Shared.group,
                                   defaults: Shared.defaults)
}

/// The start page this phone signs in to, and the app password the sign-in made for it (shared/DeviceSignIn: the
/// address and name in the app group's defaults, the password in the keychain, shared with the extension and widgets).
struct Account: Equatable {
    var server: String
    var user: String
    var password: String

    init(server: String, user: String, password: String) {
        self.server = server
        self.user = user
        self.password = password
    }

    init(_ c: DeviceCredential) {
        var s = c.base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        self.init(server: s, user: c.name, password: c.password)
    }

    static func load() -> Account? {
        LegacySignIn.migrate()
        return DeviceCredentialStore(app: .iostart).load().map(Account.init)
    }

    /// Forgets the app password (the address and name stay, for the sign-in screen) and what was kept of the tree.
    static func clear() {
        DeviceCredentialStore(app: .iostart).forgetPassword()
        Shared.defaults.removeObject(forKey: "full")
        try? FileManager.default.removeItem(at: Shared.cacheFile)
        try? FileManager.default.removeItem(at: Shared.todayFile)
    }
}

/// Before 1.3, the app password came from the start page's allow page and was kept under "sync". That sign-in
/// is gone: the old password is removed and the address and name fill the new sign-in screen.
enum LegacySignIn {
    static func migrate() {
        let d = Shared.defaults
        guard let server = d.string(forKey: "server") else { return }
        let store = DeviceCredentialStore(app: .iostart)
        if store.lastAddress == nil { store.remember(address: server, name: d.string(forKey: "user") ?? "") }
        for key in ["server", "user", "full", "lastServer"] { d.removeObject(forKey: key) }
        for group in [true, false] {
            var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Shared.keychainService,
                                    kSecAttrAccount as String: "sync"]
            if group { q[kSecAttrAccessGroup as String] = Shared.group }
            SecItemDelete(q as CFDictionary)
        }
    }
}

/// The tree as last seen, on disk.
enum TreeCache {
    static func load() -> TreeState? {
        guard let data = try? Data(contentsOf: Shared.cacheFile) else { return nil }
        return try? JSONDecoder().decode(TreeState.self, from: data)
    }

    static func save(_ state: TreeState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Shared.cacheFile, options: .atomic)
    }
}
