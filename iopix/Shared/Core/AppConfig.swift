import Foundation

/// Where things live: the server address, the settings, the files waiting to be sent and the cookies.
/// On iPhone these are shared with the share extension through an App Group; the Mac app keeps them to itself.
enum AppConfig {
    static let appGroup = "group.net.iothing.iopix"
    static let defaultServer = "https://photo.iothing.net"

    static var defaults: UserDefaults {
        #if os(iOS)
        return UserDefaults(suiteName: appGroup) ?? .standard
        #else
        return .standard
        #endif
    }

    /// A folder for the upload queue and the list of photos already seen.
    static var dataFolder: URL {
        #if os(iOS)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return ensure(group.appendingPathComponent("iopix", isDirectory: true))
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(support.appendingPathComponent("iopix", isDirectory: true))
    }

    static var cookies: HTTPCookieStorage {
        #if os(iOS)
        return HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: appGroup)
        #else
        return .shared
        #endif
    }

    static var serverURL: URL {
        get {
            let raw = defaults.string(forKey: "server") ?? defaultServer
            return URL(string: raw) ?? URL(string: defaultServer)!
        }
        set { defaults.set(newValue.absoluteString, forKey: "server") }
    }

    /// Turns what someone typed ("photo.example.net", "192.168.1.10:8600/") into a server address, or nil.
    static func normalisedServer(_ typed: String) -> URL? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = (s.first?.isNumber == true ? "http://" : "https://") + s }
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
