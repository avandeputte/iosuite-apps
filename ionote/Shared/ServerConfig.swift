import Foundation
import Security

/// Where the ionote server is. The address is a setting; the optional Cloudflare service token lives in the
/// Keychain, never in settings files. Passwords are never stored: signing in leaves a session cookie.
enum ServerConfig {
    private static let serverKey = "serverURL"

    static var serverURL: URL? {
        get { UserDefaults.standard.string(forKey: serverKey).flatMap(URL.init(string:)) }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: serverKey) }
    }

    /// Turns what someone typed ("notes.example.net", "192.168.1.10:8610/") into a server address, or nil.
    /// A bare IP address or a .local name gets http (a server on the home network), anything else https.
    static func normalisedServer(_ typed: String) -> URL? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        if !s.contains("://") {
            let host = s.split(separator: ":").first.map(String.init) ?? s
            let local = host.first?.isNumber == true || host.hasSuffix(".local") || host == "localhost" || !host.contains(".")
            s = (local ? "http://" : "https://") + s
        }
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }
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

/// A Cloudflare Access service token lets the apps through Cloudflare without its browser sign-in;
/// the ionote sign-in is still needed on top of it.
enum ServiceToken {
    static var clientID: String? {
        get { Keychain.get("cf-client-id") }
        set { Keychain.set(newValue, for: "cf-client-id") }
    }
    static var clientSecret: String? {
        get { Keychain.get("cf-client-secret") }
        set { Keychain.set(newValue, for: "cf-client-secret") }
    }
    static var isSet: Bool { clientID != nil && clientSecret != nil }
}
