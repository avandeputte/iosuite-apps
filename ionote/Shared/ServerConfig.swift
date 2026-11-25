import Foundation
import Security

/// Where the ioNote server is. This device signs in with the suite's one sign-in for apps (DeviceSignIn): the name
/// and password typed once get it an app password of its own, kept in the Keychain and sent as a Bearer header with
/// every request. The typed password is never kept. `serverURL` is the server the notes here were synced with (the
/// app's base address, e.g. https://start-api.example.com/notes); a sign-in at another server starts afresh.
enum ServerConfig {
    private static let serverKey = "serverURL"

    static var serverURL: URL? {
        get { UserDefaults.standard.string(forKey: serverKey).flatMap(URL.init(string:)) }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: serverKey) }
    }

    /// ioNote in the suite's sign-in: its folder on a suite address is /notes; at its own hostname (no folder) the
    /// sign-in is checked to have reached ioNote (GET api/status with the new app password).
    static let app = DeviceApp(name: "ioNote", folder: "notes", keychainService: "net.iothing.ionotes.device",
                               accessGroup: nil, defaults: .standard, verifyPlain: { base, password in
        var r = URLRequest(url: base.appendingPathComponent("api/status"), timeoutInterval: 10)
        r.setValue("Bearer " + password, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await DeviceSignIn.session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return ["ionote", "ioNote", "ionotes"].contains(j["app"] as? String ?? "")
    })

    static var store: DeviceCredentialStore { DeviceCredentialStore(app: app) }

    /// Whether this device holds an app password to sync with.
    static var signedIn: Bool { IonotesClient.shared.credential != nil }
}

enum Keychain {
    private static let service = "net.iothing.ionotes"

    static func get(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let query = base(account)
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

/// Before 1.6.2 a Cloudflare Access service token could be kept here; it is removed at launch.
enum LegacyServiceToken {
    static func remove() {
        Keychain.set(nil, for: "cf-client-id")
        Keychain.set(nil, for: "cf-client-secret")
    }
}
