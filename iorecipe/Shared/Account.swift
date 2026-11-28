import Foundation

/// What the app and its share extension have in common: the app group they both read.
enum Shared {
    static let group = "group.net.iothing.iorecipe"
    static let keychainService = "net.iothing.iorecipe"

    static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }

    /// Where what the server said last is kept (the list, each recipe opened, their photos), to show without a connection.
    static var cacheFolder: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Library/Caches/recipes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// The one sign-in of the ioSuite apps (shared/DeviceSignIn). ioRecipe's folder on a suite address is /recipes; at a
/// hostname of its own (no folder) the sign-in is checked to have reached ioRecipe (GET api/auth/me with the new
/// app password).
extension DeviceApp {
    static let iorecipe = DeviceApp(name: "ioRecipe", folder: "recipes", keychainService: Shared.keychainService,
                                    accessGroup: Shared.group, defaults: Shared.defaults, verifyPlain: { base, password in
        var r = URLRequest(url: base.appendingPathComponent("api/auth/me"), timeoutInterval: 10)
        r.setValue("Bearer " + password, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await DeviceSignIn.session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return j["app"] as? String == "iorecipe"
    })
}

enum Account {
    static var store: DeviceCredentialStore { DeviceCredentialStore(app: .iorecipe) }

    static func load() -> DeviceCredential? { store.load() }

    /// Forgets the app password (the address and name stay, for the sign-in screen) and what was kept of the recipes.
    static func clear() {
        store.forgetPassword()
        try? FileManager.default.removeItem(at: Shared.cacheFolder)
    }
}
