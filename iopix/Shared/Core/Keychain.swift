import Foundation
import Security

/// The optional Cloudflare service token lives in the Keychain, never in settings files.
enum Keychain {
    private static let service = "net.iothing.iopix"

    static func get(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecMissingEntitlement {  // an unsigned build has no shared keychain group
            query.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemCopyMatching(query as CFDictionary, &out)
        }
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        var query = base(account)
        if SecItemDelete(query as CFDictionary) == errSecMissingEntitlement {
            query.removeValue(forKey: kSecAttrAccessGroup as String)
            SecItemDelete(query as CFDictionary)
        }
        guard let value, !value.isEmpty else { return }
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(query as CFDictionary, nil) == errSecMissingEntitlement {
            query.removeValue(forKey: kSecAttrAccessGroup as String)
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private static func base(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        #if os(iOS)
        q[kSecAttrAccessGroup as String] = AppConfig.appGroup  // the share extension reads it too
        #endif
        return q
    }
}

/// A Cloudflare Access service token lets uploads through Cloudflare without the browser sign-in,
/// which expires; the iopix sign-in is still needed on top of it.
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

    /// Cloudflare checks these two headers before anything else: with a token its policy allows, the request goes
    /// straight through to iopix, without Cloudflare's sign-in page.
    static func apply(to r: inout URLRequest) {
        guard let id = clientID, let secret = clientSecret else { return }
        r.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
        r.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
    }

    /// Said when Cloudflare still shows its sign-in although a token was sent: a wrong or revoked token, or one
    /// the iopix application's policies don't allow.
    static let rejected = "Cloudflare Access didn't accept the service token. Check its client ID and secret, and that the ioPix application in Cloudflare Zero Trust has a Service Auth policy that allows this token."

    /// Is this the sign-in page of Cloudflare Access (team.cloudflareaccess.com)?
    static func isCloudflareSignIn(_ url: URL?) -> Bool {
        url?.host?.lowercased().hasSuffix(".cloudflareaccess.com") == true
    }
}
