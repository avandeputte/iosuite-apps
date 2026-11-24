import Foundation

/// Where things live: the server address, the settings and the files waiting to be sent.
/// On iPhone and Apple TV these are shared with the extensions (share sheet, Top Shelf) through an App Group; the
/// Mac app keeps them to itself.
enum AppConfig {
    static let appGroup = "group.net.iothing.iopix"
    /// The Mac app and its extensions (Share menu, widget) share this one (macOS groups start with the team id).
    static let macGroup = "69M2JRAT8P.net.iothing.iopix"
    static let defaultServer = "https://photo.iothing.net"

    /// The App Group is there only when the app was signed with it; without it everything stays in the app.
    static let hasGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil

    static var defaults: UserDefaults {
        #if os(iOS) || os(tvOS)
        return hasGroup ? (UserDefaults(suiteName: appGroup) ?? .standard) : .standard
        #else
        return .standard
        #endif
    }

    /// A folder for the upload queue and the list of photos already seen.
    static var dataFolder: URL {
        #if os(iOS) || os(tvOS)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return ensure(group.appendingPathComponent("iopix", isDirectory: true))
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(support.appendingPathComponent("iopix", isDirectory: true))
    }

    /// The device sign-in (shared/DeviceSignIn): ioPix lives in the "pix" folder of a suite address, or at an address
    /// of its own. The app password is kept in the Keychain group the extensions share.
    static let deviceApp = DeviceApp(
        name: "ioPix", folder: "pix", keychainService: "net.iothing.iopix.device",
        accessGroup: {
            #if os(macOS)
            return macGroup
            #else
            return hasGroup ? appGroup : nil
            #endif
        }(),
        defaults: defaults,
        verifyPlain: { base, password in
            // signed in at an address without the folder: is it ioPix that answered (its own hostname)?
            var r = URLRequest(url: base.appendingPathComponent("api/status"), timeoutInterval: 15)
            r.setValue("Bearer " + password, forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, _) = try? await DeviceSignIn.session.data(for: r),
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            return (j["app"] as? String) == "iopix"
        })

    /// The address of ioPix on the home network, for the admin and maintenance screens (which the port for devices
    /// does not serve): e.g. http://192.168.1.10:8080/pix. nil when none was given.
    static var homeURL: URL? {
        get { defaults.string(forKey: "homeServer").flatMap(URL.init(string:)) }
        set { defaults.set(newValue?.absoluteString, forKey: "homeServer") }
    }

    /// The address of ioPix the app talks to: where the device sign-in answered.
    static var serverURL: URL {
        get {
            let raw = defaults.string(forKey: "server") ?? defaultServer
            return URL(string: raw) ?? URL(string: defaultServer)!
        }
        set { defaults.set(newValue.absoluteString, forKey: "server") }
    }

    /// False until this device has signed in somewhere once.
    static var hasServer: Bool { defaults.string(forKey: "server") != nil }

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
