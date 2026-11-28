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

/// ioMoney's API (`/api/…` below the app's base address), called with the app password the sign-in made for this
/// device (shared/DeviceSignIn) as a Bearer token. The address for devices serves the calls listed in the server's
/// iomoney/app.json ("devices"): a call added here has to be added there. The server answers as the person signed
/// in: an account someone keeps private is never in an answer to anyone else.
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

    func url(_ path: String) -> URL { DeviceSignIn.url(credential.base, path) }

    private static func message(_ data: Data) -> String {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        return j["detail"] as? String ?? j["error"] as? String ?? ""
    }

    func data(_ method: String, _ path: String, body: Data? = nil, type: String = "application/json") async throws -> Data {
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
            let (d, resp) = try await API.session.data(for: req)
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

    func call<T: Decodable>(_ method: String, _ path: String, json: Any? = nil) async throws -> T {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let data = try await data(method, path, body: body)
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw APIError.unreachable("The server's answer could not be read. Is it up to date?")
        }
    }

    private static func q(_ s: String) -> String {
        var ok = CharacterSet.urlQueryAllowed
        ok.remove(charactersIn: "&+=?#")
        return s.addingPercentEncoding(withAllowedCharacters: ok) ?? ""
    }

    // MARK: overview and accounts

    func summary() async throws -> Summary { try await call("GET", "api/summary") }
    func netWorth(days: Int) async throws -> NetWorth { try await call("GET", "api/networth?days=\(days)") }

    func accounts() async throws -> [MoneyAccount] {
        let got: Items<MoneyAccount> = try await call("GET", "api/accounts")
        return got.items
    }

    func account(_ id: Int) async throws -> MoneyAccount { try await call("GET", "api/accounts/\(id)") }

    func history(_ id: Int, days: Int) async throws -> [DayValue] {
        let got: Items<DayValue> = try await call("GET", "api/accounts/\(id)/history?days=\(days)")
        return got.items
    }

    func forecast(_ id: Int, days: Int = 60) async throws -> Forecast { try await call("GET", "api/accounts/\(id)/forecast?days=\(days)") }

    func forecastWarnings() async throws -> [ForecastWarning] {
        let got: Items<ForecastWarning> = try await call("GET", "api/forecast")
        return got.items
    }

    // MARK: transactions

    /// Which transactions a list shows.
    struct Query: Hashable {
        var q = ""
        var account: Int?
        var category: String?
        /// YYYY-MM
        var month: String?
        /// "out" or "in"
        var flow: String?
        /// Only those that need a look.
        var review = false

        var isEmpty: Bool { self == Query() }
    }

    func transactions(_ query: Query, limit: Int = 60, offset: Int = 0) async throws -> TransactionPage {
        var parts = ["limit=\(limit)", "offset=\(offset)"]
        let words = query.q.trimmingCharacters(in: .whitespaces)
        if !words.isEmpty { parts.append("q=" + API.q(words)) }
        if let a = query.account { parts.append("account=\(a)") }
        if let c = query.category { parts.append("category=" + API.q(c)) }
        if let m = query.month { parts.append("month=" + m) }
        if let f = query.flow { parts.append("flow=" + f) }
        if query.review { parts.append("review=yes") }
        return try await call("GET", "api/transactions?" + parts.joined(separator: "&"))
    }

    func transaction(_ id: Int) async throws -> Transaction { try await call("GET", "api/transactions/\(id)") }

    /// {category?, merchant?, notes?, hidden?, reviewed?, tags?}: kept as changed here, also by the next sync.
    func change(_ id: Int, _ fields: [String: Any]) async throws -> Transaction {
        try await call("PATCH", "api/transactions/\(id)", json: fields)
    }

    /// Marked as looked at (or not). How many still need a look.
    func review(_ ids: [Int], reviewed: Bool = true) async throws -> Int {
        let got: ReviewAnswer = try await call("POST", "api/transactions/review", json: ["ids": ids, "reviewed": reviewed])
        return got.left
    }

    func categories() async throws -> [Category] {
        let got: Items<Category> = try await call("GET", "api/categories")
        return got.items
    }

    // MARK: receipts

    func addReceipt(_ transaction: Int, data: Data, mime: String, name: String) async throws -> Receipt {
        let got = try await self.data("POST", "api/transactions/\(transaction)/receipts?name=" + API.q(name), body: data, type: mime)
        do { return try JSONDecoder().decode(Receipt.self, from: got) } catch {
            throw APIError.unreachable("The server's answer could not be read. Is it up to date?")
        }
    }

    func receipt(_ id: Int) async throws -> Data { try await data("GET", "api/receipts/\(id)") }
    func deleteReceipt(_ id: Int) async throws { let _: Done = try await call("DELETE", "api/receipts/\(id)") }

    // MARK: spending, bills, the portfolio

    func spending(month: String) async throws -> Spending { try await call("GET", "api/spending?month=" + month) }
    func cashFlow(months: Int = 12) async throws -> CashFlow { try await call("GET", "api/cashflow?months=\(months)") }

    func bills(start: Date, end: Date) async throws -> [Bill] {
        let got: Items<Bill> = try await call("GET", "api/bills?start=\(Day.string(start))&end=\(Day.string(end))")
        return got.items
    }

    func portfolio() async throws -> Portfolio { try await call("GET", "api/portfolio") }
}
