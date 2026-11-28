import Foundation

enum APIError: LocalizedError {
    case signedOut
    case server(Int, String)
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "The server no longer accepts this device's sign-in. Sign in again."
        case .server(let code, let msg): return msg.isEmpty ? "The server answered with an error (\(code))." : msg
        case .unreachable(let msg): return msg
        }
    }

    /// No connection, or no answer: what was kept is shown instead.
    var isOffline: Bool {
        if case .unreachable = self { return true }
        return false
    }
}

/// ioRecipe's API (`/api/…` below the app's base address), called with the app password the sign-in made for this
/// device (shared/DeviceSignIn) as a Bearer token. The address for devices serves the calls listed in the server's
/// iorecipe/app.json ("devices"): a call added here has to be added there.
struct API {
    var credential: DeviceCredential

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    /// An import reads a web page, and sometimes has the server's own AI model read it: that takes minutes.
    static let patient: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 330
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    func url(_ path: String) -> URL { DeviceSignIn.url(credential.base, path) }

    private static func message(_ data: Data) -> String {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        return j["detail"] as? String ?? j["error"] as? String ?? ""
    }

    func data(_ method: String, _ path: String, body: Data? = nil, type: String = "application/json", patient: Bool = false) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        credential.authorize(&req)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue(type, forHTTPHeaderField: "Content-Type")
        }
        let data: Data, http: HTTPURLResponse
        do {
            let (d, resp) = try await (patient ? API.patient : API.session).data(for: req)
            guard let h = resp as? HTTPURLResponse else { throw APIError.unreachable("The server did not answer.") }
            data = d; http = h
        } catch let e as APIError {
            throw e
        } catch let e as URLError {
            throw APIError.unreachable(DeviceSignIn.explain(e, host: credential.base.host ?? "the server"))
        } catch {
            throw APIError.unreachable("Couldn't reach \(credential.base.host ?? "the server"): \(error.localizedDescription)")
        }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw APIError.signedOut
        case 404 where API.message(data).isEmpty:
            throw APIError.server(404, "The server does not know this. Is it up to date?")
        default: throw APIError.server(http.statusCode, API.message(data))
        }
    }

    func call<T: Decodable>(_ method: String, _ path: String, json: Any? = nil, patient: Bool = false) async throws -> T {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let data = try await data(method, path, body: body, patient: patient)
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw APIError.unreachable("The server's answer could not be read. Is it up to date?")
        }
    }

    private static func q(_ s: String) -> String {
        var ok = CharacterSet.urlQueryAllowed
        ok.remove(charactersIn: "&+=?#")
        return s.addingPercentEncoding(withAllowedCharacters: ok) ?? ""
    }

    // MARK: recipes

    func me() async throws -> Me { try await call("GET", "api/auth/me") }

    /// The recipes one sees. scope: family, mine or favourites; sort: title, new or rating.
    func recipes(q: String = "", tag: String? = nil, scope: String? = nil, book: Int? = nil, sort: String? = nil) async throws -> Listing {
        var parts: [String] = []
        if !q.isEmpty { parts.append("q=" + API.q(q)) }
        if let tag { parts.append("tag=" + API.q(tag)) }
        if let scope { parts.append("scope=" + scope) }
        if let book { parts.append("book=\(book)") }
        if let sort { parts.append("sort=" + sort) }
        return try await call("GET", "api/recipes" + (parts.isEmpty ? "" : "?" + parts.joined(separator: "&")))
    }

    func recipe(_ id: Int) async throws -> Recipe { try await call("GET", "api/recipes/\(id)") }

    func delete(_ id: Int) async throws { let _: Done = try await call("DELETE", "api/recipes/\(id)") }

    func setFavourite(_ id: Int, _ on: Bool) async throws -> Recipe {
        try await call("PUT", "api/recipes/\(id)/mark", json: ["favourite": on])
    }

    /// 1 to 5, or nil to take the rating away.
    func setRating(_ id: Int, _ stars: Int?) async throws -> Recipe {
        try await call("PUT", "api/recipes/\(id)/mark", json: ["rating": stars.map { $0 as Any } ?? NSNull()])
    }

    // MARK: photos

    /// One more photo of the recipe, or with step the picture of that step (JPEG data).
    func addPhoto(_ id: Int, jpeg: Data, step: Int? = nil) async throws -> Recipe {
        let data = try await data("POST", "api/recipes/\(id)/photos" + (step.map { "?step=\($0)" } ?? ""), body: jpeg, type: "image/jpeg")
        return try JSONDecoder().decode(Recipe.self, from: data)
    }

    func deletePhoto(_ id: Int, photo: Int) async throws -> Recipe { try await call("DELETE", "api/recipes/\(id)/photos/\(photo)") }

    /// The recipe's own photos in this order: the first is the one its card shows.
    func orderPhotos(_ id: Int, ids: [Int]) async throws -> Recipe {
        try await call("PUT", "api/recipes/\(id)/photos/order", json: ["ids": ids])
    }

    // MARK: cookbooks

    func putInBook(_ book: Int, recipe: Int) async throws { let _: Done = try await call("PUT", "api/books/\(book)/recipes/\(recipe)") }
    func takeFromBook(_ book: Int, recipe: Int) async throws { let _: Done = try await call("DELETE", "api/books/\(book)/recipes/\(recipe)") }

    // MARK: import

    func importWays() async throws -> ImportWays { try await call("GET", "api/import") }

    /// The recipe on that web page, kept as a new recipe.
    func importPage(_ address: String, family: Bool? = nil) async throws -> Recipe {
        var body: [String: Any] = ["url": address]
        if let family { body["family"] = family }
        return try await call("POST", "api/import", json: body, patient: true)
    }

    /// Pasted text as a draft for the form; nothing is saved.
    func draft(text: String) async throws -> Draft {
        let a: DraftAnswer = try await call("POST", "api/import/text", json: ["text": text])
        return a.draft
    }

    /// A photo of a recipe (a page of a book, a card), read on the server into a draft; nothing is saved.
    func draft(photo jpeg: Data) async throws -> Draft {
        let data = try await data("POST", "api/import/photo", body: jpeg, type: "image/jpeg", patient: true)
        return try JSONDecoder().decode(DraftAnswer.self, from: data).draft
    }
}
