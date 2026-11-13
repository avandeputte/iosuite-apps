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
}

/// The start page this phone syncs with, and the sync-only app password the sign-in made for it.
/// The address and name sit in the app group's defaults; the password in the keychain, shared with the extension.
struct Account: Equatable {
    var server: String
    var user: String
    var password: String

    static func load() -> Account? {
        let d = Shared.defaults
        guard let server = d.string(forKey: "server"), let user = d.string(forKey: "user"), let pw = Keychain.read() else { return nil }
        return Account(server: server, user: user, password: pw)
    }

    func save() {
        let d = Shared.defaults
        d.set(server, forKey: "server")
        d.set(user, forKey: "user")
        Keychain.write(password)
    }

    static func clear() {
        let d = Shared.defaults
        d.removeObject(forKey: "server")
        d.removeObject(forKey: "user")
        Keychain.delete()
        try? FileManager.default.removeItem(at: Shared.cacheFile)
    }
}

enum Keychain {
    private static func query(group: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Shared.keychainService,
            kSecAttrAccount as String: "sync",
        ]
        if group { q[kSecAttrAccessGroup as String] = Shared.group }
        return q
    }

    static func read() -> String? {
        for group in [true, false] {
            var q = query(group: group)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8) {
                return s
            }
        }
        return nil
    }

    static func write(_ password: String) {
        delete()
        for group in [true, false] {  // without the group only when the shared keychain is not available (then the extension asks to sign in)
            var q = query(group: group)
            q[kSecValueData as String] = Data(password.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if SecItemAdd(q as CFDictionary, nil) == errSecSuccess { return }
        }
    }

    static func delete() {
        for group in [true, false] { SecItemDelete(query(group: group) as CFDictionary) }
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
