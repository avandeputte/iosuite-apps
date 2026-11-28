import Foundation

/// The one sign-in of the ioSuite apps (shared/DeviceSignIn). ioMoney's folder on a suite address is /money; at a
/// hostname of its own (no folder) the sign-in is checked to have reached ioMoney (GET api/auth/me with the new app
/// password). Nothing of the accounts is kept on the device: every screen asks the server.
extension DeviceApp {
    static let iomoney = DeviceApp(name: "ioMoney", folder: "money", keychainService: "net.iothing.iomoney",
                                   accessGroup: nil, defaults: .standard, verifyPlain: { base, password in
        var r = URLRequest(url: base.appendingPathComponent("api/auth/me"), timeoutInterval: 10)
        r.setValue("Bearer " + password, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await DeviceSignIn.session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return j["app"] as? String == "iomoney"
    })
}

enum Account {
    static var store: DeviceCredentialStore { DeviceCredentialStore(app: .iomoney) }
    static func load() -> DeviceCredential? { store.load() }
    /// Forgets the app password; the address and name stay, for the sign-in screen.
    static func clear() { store.forgetPassword() }
}
