import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

// The one sign-in of the ioSuite apps (ioStart, ioPix, ioNote, ioHealthSync, ioRecipe, ioMoney), the same file in each of them.
//
// The person types the server's address for apps, their name and password (and the code of two-step sign-in when the
// server asks for it). POST <app base>/api/auth/device trades them for an app password of this device, which is kept
// in the Keychain and sent as "Authorization: Bearer <app password>" with every request after that. The typed password
// is never kept. Signing out gives the app password back (DELETE <app base>/api/auth/device) and forgets it.

/// What tells one app from another in the sign-in.
struct DeviceApp {
    /// "ioPix": shown in messages and in the device's label in Settings › Account.
    let name: String
    /// The app's folder on a suite address ("pix", "notes", "health"); "" for the start page at the root.
    let folder: String
    /// Keychain service the app password is kept under.
    let keychainService: String
    /// Keychain access group shared with the app's widgets and extensions (an app group), or nil.
    let accessGroup: String?
    /// Where the address and name are kept (the app group's defaults when extensions read them).
    let defaults: UserDefaults
    /// After signing in at the plain address (no folder): whether this really is the app, asked with the new app
    /// password. nil: an app that is only ever at its folder (or the root) never falls back to the plain address.
    var verifyPlain: ((URL, String) async -> Bool)? = nil
}

/// The address, the name and the app password of this device.
struct DeviceCredential: Equatable {
    /// The address as the person gave it (tidied), to fill the sign-in screen with again.
    var address: String
    /// The app's base address the sign-in answered at: every call is made below it ("https://host/pix").
    var base: URL
    var name: String
    var password: String

    var bearer: String { "Bearer " + password }

    /// Adds the app password to a request.
    func authorize(_ request: inout URLRequest) {
        request.setValue(bearer, forHTTPHeaderField: "Authorization")
    }

    /// The header for AVURLAsset (AVURLAssetHTTPHeaderFieldsKey), web image loaders and the like.
    var headers: [String: String] { ["Authorization": bearer] }
}

enum DeviceSignInError: LocalizedError, Equatable {
    case badAddress
    case needsCode(String)
    case wrongPassword
    case tooMany(Int)
    case noAccess(String)
    case notFound
    /// A 401 that is not the sign-in's own answer (an app at that address asking for a sign-in to reach the page at
    /// all, e.g. an ioPix of its own hostname asked below /pix): not here; try the next address.
    case notTheSignIn
    case server(Int, String)
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .badAddress: return "That doesn't look like a server address."
        case .needsCode(let why): return why.isEmpty ? "Enter the code from your code app." : why
        case .wrongPassword: return "Wrong name or password."
        case .tooMany(let s): return "Too many attempts. Wait \(s) seconds and try again."
        case .noAccess(let why): return why
        case .notFound, .notTheSignIn: return "No ioSuite server for apps answers at that address. Check the address."
        case .server(let code, let why): return why.isEmpty ? "The server answered with error \(code)." : why
        case .unreachable(let why): return why
        }
    }
}

enum DeviceSignIn {
    static let addressHint = "Your server's address for apps, e.g. https://start-api.example.com"
    static let explanation = "Sign in with the name and password of your ioSuite account. This device gets a password of its own, which you can remove in Settings › Account. Your password itself is not kept."

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    // MARK: address

    /// What was typed, with a scheme and without a trailing slash: an address on the home network (an IP address,
    /// a .local name, localhost, a name without a dot) gets http, anything else https.
    static func tidy(_ typed: String) -> URL? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        if !s.contains("://") {
            let host = s.split(separator: "/").first.map(String.init) ?? s
            let name = host.split(separator: ":").first.map(String.init) ?? host
            let local = name.first?.isNumber == true || name.hasSuffix(".local") || name == "localhost" || !name.contains(".")
            s = (local ? "http://" : "https://") + s
        }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    /// The addresses to try the sign-in at, best first: the address with the app's folder added (not twice when it
    /// already ends in it), then, for an app that has its own hostname too, the address as it was typed.
    static func candidates(_ typed: String, app: DeviceApp) -> [URL] {
        guard let url = tidy(typed) else { return [] }
        if app.folder.isEmpty { return [url] }
        let path = url.path.lowercased()
        if path == "/" + app.folder || path.hasSuffix("/" + app.folder) { return [url] }
        let withFolder = url.appendingPathComponent(app.folder)
        return app.verifyPlain == nil ? [withFolder] : [withFolder, url]
    }

    /// A URL below the app's base: "api/photos?x=1" keeps its query.
    static func url(_ base: URL, _ path: String) -> URL {
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var url = base.appendingPathComponent(parts.first ?? "")
        if parts.count == 2, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.percentEncodedQuery = parts[1]
            url = c.url ?? url
        }
        return url
    }

    // MARK: the device's name

    static var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    static func label(for app: DeviceApp) -> String { "\(app.name) on \(deviceName)" }

    // MARK: signing in and out

    struct Answer {
        var credential: DeviceCredential
        /// The account as the server describes it ({id, name, role, …}) and the account's settings in this app.
        var user: [String: Any]
        var settings: [String: Any]
    }

    /// Signs in at the first address that has the app. `code` only once the server asked for it (needsCode).
    static func signIn(app: DeviceApp, address typed: String, name: String, password: String, code: String?) async throws -> Answer {
        let urls = candidates(typed, app: app)
        guard !urls.isEmpty else { throw DeviceSignInError.badAddress }
        let address = tidy(typed)?.absoluteString ?? typed
        var lastError: Error = DeviceSignInError.notFound
        for (i, base) in urls.enumerated() {
            do {
                var answer = try await signIn(app: app, base: base, name: name, password: password, code: code)
                answer.credential.address = address
                if i > 0, let verify = app.verifyPlain, !(await verify(base, answer.credential.password)) {
                    await signOut(answer.credential)  // another app answered at the plain address: give its password back
                    throw DeviceSignInError.notFound
                }
                return answer
            } catch DeviceSignInError.notFound {
                if case DeviceSignInError.notTheSignIn = lastError {} else { lastError = DeviceSignInError.notFound }
                continue
            } catch DeviceSignInError.notTheSignIn {
                lastError = DeviceSignInError.notTheSignIn  // reported as a wrong name or password when no address takes it
                continue
            }
        }
        if case DeviceSignInError.notTheSignIn = lastError { throw DeviceSignInError.wrongPassword }
        if case DeviceSignInError.notFound = lastError {
            throw DeviceSignInError.unreachable("\(tidy(typed)?.host ?? "That address") answers, but not with \(app.name)'s sign-in (error 404). "
                + "Check that it is your server's address for apps, and that \(app.name) is installed there.")
        }
        throw lastError
    }

    private static func signIn(app: DeviceApp, base: URL, name: String, password: String, code: String?) async throws -> Answer {
        var r = URLRequest(url: base.appendingPathComponent("api/auth/device"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["name": name.trimmingCharacters(in: .whitespacesAndNewlines), "password": password,
                                   "label": label(for: app), "scope": ""]
        if let code, !code.isEmpty { body["code"] = code.trimmingCharacters(in: .whitespacesAndNewlines) }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, http: HTTPURLResponse
        do {
            let (d, resp) = try await session.data(for: r)
            guard let h = resp as? HTTPURLResponse else { throw DeviceSignInError.unreachable("The server did not answer.") }
            data = d; http = h
        } catch let e as DeviceSignInError {
            throw e
        } catch let e as URLError {
            throw DeviceSignInError.unreachable(DeviceSignIn.explain(e, host: base.host ?? "the server"))
        } catch {
            throw DeviceSignInError.unreachable("Couldn't reach \(base.host ?? "the server"): \(error.localizedDescription)")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = json?["detail"] as? String ?? ""
        switch http.statusCode {
        case 200:
            if json == nil {  // a web page (a proxy's sign-in, another site) rather than the suite's answer
                throw DeviceSignInError.unreachable("\(base.host ?? "That address") answered with a web page, not ioSuite's sign-in. "
                    + "Check that the address is your server's address for apps.")
            }
            guard let pw = json?["password"] as? String, !pw.isEmpty else {
                throw DeviceSignInError.server(200, "The server's answer could not be read. Is it up to date?")
            }
            let who = json?["name"] as? String ?? name
            return Answer(credential: DeviceCredential(address: base.absoluteString, base: base, name: who, password: pw),
                          user: json?["user"] as? [String: Any] ?? [:], settings: json?["settings"] as? [String: Any] ?? [:])
        case 401:
            if json?["twoStep"] as? Bool == true { throw DeviceSignInError.needsCode(detail) }
            // the sign-in's own refusal names the name or the password; anything else is a page asking for a sign-in
            if detail.lowercased().contains("password") || detail.lowercased().contains("user name") || detail.isEmpty {
                throw DeviceSignInError.wrongPassword
            }
            throw DeviceSignInError.notTheSignIn
        case 429:
            let wait = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            throw DeviceSignInError.tooMany(wait)
        case 403:
            throw DeviceSignInError.noAccess(detail.isEmpty ? "This account has no access to \(app.name)." : detail)
        case 404, 405:
            throw DeviceSignInError.notFound
        case 502, 503, 504:
            // the server, or the proxy or tunnel in front of it (a 503 "no server is available"), is not taking requests
            throw DeviceSignInError.unreachable("The server at \(base.host ?? "that address") isn't available right now (error \(http.statusCode)). "
                + "Try again in a moment. If it stays this way, the proxy or tunnel in front of it can't reach ioSuite.")
        default:
            if json == nil {  // a web page, a proxy's own answer: not the suite's port for apps
                throw DeviceSignInError.unreachable("\(base.host ?? "That address") answered with error \(http.statusCode) and a web page, "
                    + "not ioSuite's sign-in. Check that the address is your server's address for apps.")
            }
            throw DeviceSignInError.server(http.statusCode, detail)
        }
    }

    /// What went wrong with the connection itself, in plain words.
    static func explain(_ e: URLError, host: String) -> String {
        switch e.code {
        case .cannotFindHost, .dnsLookupFailed:
            return "No server is called \(host). Check the address."
        case .cannotConnectToHost:
            return "\(host) refused the connection. Is the server (or the port in the address) right?"
        case .timedOut:
            return "\(host) didn't answer in time. Check the address, or try again in a moment."
        case .notConnectedToInternet, .networkConnectionLost:
            return "This device is offline. Connect to the internet and try again."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "The secure connection to \(host) failed: its certificate isn't valid (expired, or not made for that name)."
        case .appTransportSecurityRequiresSecureConnection:
            return "\(host) needs an https:// address (plain http only works on your home network)."
        default:
            return "Couldn't reach \(host): \(e.localizedDescription)"
        }
    }

    /// Gives this device's app password back to the server. Failing quietly: the device forgets it either way.
    static func signOut(_ credential: DeviceCredential) async {
        var r = URLRequest(url: credential.base.appendingPathComponent("api/auth/device"))
        r.httpMethod = "DELETE"
        r.timeoutInterval = 10
        credential.authorize(&r)
        _ = try? await session.data(for: r)
    }
}

/// Where the credential is kept: the address and name in defaults, the app password in the Keychain.
struct DeviceCredentialStore {
    let app: DeviceApp

    private var d: UserDefaults { app.defaults }

    func load() -> DeviceCredential? {
        guard let address = d.string(forKey: "device.address"), let baseText = d.string(forKey: "device.base"),
              let base = URL(string: baseText), let name = d.string(forKey: "device.name"),
              let pw = DeviceKeychain(app: app).read(), !pw.isEmpty else { return nil }
        return DeviceCredential(address: address, base: base, name: name, password: pw)
    }

    func save(_ c: DeviceCredential) {
        d.set(c.address, forKey: "device.address")
        d.set(c.base.absoluteString, forKey: "device.base")
        d.set(c.name, forKey: "device.name")
        DeviceKeychain(app: app).write(c.password)
    }

    /// Forgets the app password and keeps the address and name, to fill the sign-in screen with again.
    func forgetPassword() {
        DeviceKeychain(app: app).delete()
    }

    /// The address and name last signed in with (also after a sign-out), for the sign-in screen.
    var lastAddress: String? { d.string(forKey: "device.address") }
    var lastName: String? { d.string(forKey: "device.name") }
    var lastBase: URL? { d.string(forKey: "device.base").flatMap(URL.init(string:)) }

    func remember(address: String, name: String) {
        d.set(address, forKey: "device.address")
        d.set(name, forKey: "device.name")
    }
}

/// The app password in the Keychain: in the shared access group when the app was signed with it (widgets and
/// extensions read it there), otherwise the app's own.
struct DeviceKeychain {
    let app: DeviceApp

    private func queries() -> [[String: Any]] {
        var base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: app.keychainService,
                                   kSecAttrAccount as String: "device"]
        var out: [[String: Any]] = []
        if let group = app.accessGroup {
            var q = base
            q[kSecAttrAccessGroup as String] = group
            #if os(macOS)
            q[kSecUseDataProtectionKeychain as String] = true
            #endif
            out.append(q)
        }
        #if os(macOS)
        var dp = base
        dp[kSecUseDataProtectionKeychain as String] = true
        out.append(dp)
        #endif
        base[kSecAttrService as String] = app.keychainService
        out.append(base)
        return out
    }

    func read() -> String? {
        for var q in queries() {
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
               let s = String(data: data, encoding: .utf8) { return s }
        }
        return nil
    }

    func write(_ password: String) {
        delete()
        for var q in queries() {
            q[kSecValueData as String] = Data(password.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if SecItemAdd(q as CFDictionary, nil) == errSecSuccess { return }
        }
    }

    func delete() {
        for q in queries() { SecItemDelete(q as CFDictionary) }
    }
}
