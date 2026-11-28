import Foundation

// What ioMoney's API answers (iomoney/routes in the server). Amounts are signed as the server signs them: money out is
// negative; a liability's `value` is negative, its `balance` what is owed.

struct GroupValue: Decodable, Hashable {
    var group: String
    var label: String
    var value: Double
}

struct NetWorth: Decodable {
    struct Point: Decodable, Identifiable {
        var day: String
        var value: Double
        var id: String { day }
        var date: Date { Day.date(day) }
    }
    var currency: String
    var assets: Double
    var liabilities: Double
    var netWorth: Double
    var byGroup: [GroupValue]
    var history: [Point]?
}

/// GET /api/summary: what is around every screen.
struct Summary: Decodable {
    struct Group: Decodable, Hashable {
        var group: String
        var label: String
    }
    struct Stale: Decodable, Identifiable, Hashable {
        var id: Int
        var name: String
        var institution: String?
        var why: String?
    }
    struct Monarch: Decodable {
        var stale: [Stale]
    }
    struct May: Decodable {
        var read: Bool
    }
    var netWorth: NetWorth
    var currency: String
    var groups: [Group]
    var monarch: Monarch?
    /// How many transactions need a look.
    var review: Int
    var may: May
}

struct MoneyAccount: Decodable, Identifiable, Hashable {
    struct Bank: Decodable, Hashable {
        var stale: String?
        var why: String?
    }
    var id: Int
    var name: String
    var institution: String?
    var kind: String
    var kindLabel: String
    var subtype: String?
    var isAsset: Bool
    /// In its own currency; what is owed for a liability.
    var balance: Double
    var currency: String
    /// In the household's currency; negative for a liability.
    var value: Double
    var inNetWorth: Bool
    var closed: Bool
    var mask: String?
    var household: Bool
    var group: String
    /// "transactions": they are listed; "value": its balance or value alone.
    var track: String
    var bank: Bank?

    var detail: String {
        [institution, mask.map { "••\($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct Items<T: Decodable>: Decodable {
    var items: [T]
}

struct DayValue: Decodable, Identifiable {
    var day: String
    var value: Double
    var id: String { day }
    var date: Date { Day.date(day) }
}

/// GET /api/accounts/{id}/forecast: the balance over the coming days, from the recurring transactions.
struct Forecast: Decodable {
    struct Event: Decodable, Identifiable {
        var day: String
        var name: String
        var amount: Double
        var approximate: Bool
        var late: Bool
        var balance: Double
        var id: String { day + name + String(amount) }
    }
    struct Low: Decodable {
        var day: String
        var value: Double
    }
    var currency: String
    var start: Double
    var days: Int
    var floor: Double?
    var end: Double
    var events: [Event]
    var points: [DayValue]
    var low: Low?
    var below: Bool
    var belowOn: String?
}

/// GET /api/forecast: the cash accounts that would go under their lowest balance.
struct ForecastWarning: Decodable, Identifiable {
    var accountId: Int
    var name: String
    var currency: String
    var belowOn: String?
    var low: Forecast.Low?
    var id: Int { accountId }
}

struct Receipt: Decodable, Identifiable, Hashable {
    var id: Int
    var name: String
    var mime: String
    var size: Int
}

struct Transaction: Decodable, Identifiable, Hashable {
    struct Transfer: Decodable, Hashable {
        var id: Int?
        var accountId: Int?
        var account: String?
    }
    var id: Int
    var accountId: Int
    var account: String?
    var day: String
    var amount: Double
    var currency: String?
    /// The payee, as named here.
    var merchant: String?
    /// The bank's own text.
    var description: String?
    var category: String?
    var group: String?
    var notes: String?
    /// Every tag: Monarch's and those set here.
    var tags: [String]
    /// Those set here, which can be changed.
    var ownTags: [String]?
    var hidden: Bool
    var writable: Bool?
    var receipts: [Receipt]?
    /// The other half, when this is money moved between two of the household's accounts.
    var transfer: Transfer?

    var title: String {
        if let m = merchant, !m.isEmpty { return m }
        if let d = description, !d.isEmpty { return d }
        return "No payee"
    }

    /// The category, or where a transfer went.
    var what: String {
        if let t = transfer, let other = t.account { return (amount < 0 ? "To " : "From ") + other }
        return category ?? "No category"
    }
}

struct TransactionPage: Decodable {
    var items: [Transaction]
    var total: Int
    var sum: Double
}

struct Category: Decodable, Hashable {
    var category: String
    var group: String?
}

struct Spending: Decodable {
    struct Line: Decodable, Identifiable {
        var category: String?
        var group: String?
        var spent: Double
        var income: Double
        var count: Int
        var id: String { category ?? "-" }
    }
    var currency: String
    var spent: Double
    var income: Double
    var net: Double
    var categories: [Line]
}

struct CashFlow: Decodable {
    struct Month: Decodable, Identifiable {
        var month: String
        var spent: Double
        var income: Double
        var net: Double
        var id: String { month }
    }
    var currency: String
    var items: [Month]
}

struct Bill: Decodable, Identifiable {
    struct Provider: Decodable {
        var accountNumber: String?
        var phone: String?
        var website: String?
        var note: String?
    }
    var recurring: Int
    var day: String
    var merchant: String
    var amount: Double
    var currency: String?
    var approximate: Bool
    var frequency: String?
    var category: String?
    var account: String?
    var subscription: Bool
    var paid: Bool
    var transactionId: Int?
    var provider: Provider?
    var id: String { "\(recurring)-\(day)" }

    enum CodingKeys: String, CodingKey {
        case recurring = "id", day, merchant, amount, currency, approximate, frequency, category, account, subscription, paid, transactionId, provider
    }
}

struct Portfolio: Decodable {
    struct Holding: Decodable, Identifiable {
        var id: Int
        var accountId: Int
        var account: String?
        var symbol: String?
        var name: String?
        var shares: Double?
        var price: Double?
        var currency: String?
        var homeValue: Double?
        var dayChange: Double?
        var dayChangePct: Double?
        var gain: Double?
    }
    struct Symbol: Decodable, Identifiable {
        var symbol: String?
        var name: String?
        var shares: Double?
        var price: Double?
        var currency: String?
        var homeValue: Double?
        var dayChange: Double?
        var dayChangePct: Double?
        var id: String { (symbol ?? "") + (name ?? "") }
    }
    var currency: String
    var value: Double
    var dayChange: Double?
    var dayChangePct: Double?
    var gain: Double?
    var items: [Holding]
    var bySymbol: [Symbol]
}

struct ReviewAnswer: Decodable {
    var left: Int
}

struct Done: Decodable {
    var ok: Bool?
}

/// Days as the server writes them (2026-11-28), and amounts of money as people read them.
enum Day {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ day: String) -> Date { parser.date(from: String(day.prefix(10))) ?? .distantPast }
    static func string(_ date: Date) -> String { parser.string(from: date) }

    /// "Sat 28 Nov", with the year when it is not this one.
    static func label(_ day: String) -> String {
        let d = date(day)
        let same = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year)
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(same ? .dateTime.weekday(.abbreviated).day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year())
    }

    /// "2026-11" as "November 2026".
    static func month(_ month: String) -> String {
        date(month + "-01").formatted(.dateTime.month(.wide).year())
    }
}

enum Money {
    static func text(_ amount: Double, _ currency: String?, cents: Bool = true, sign: Bool = false) -> String {
        var style = FloatingPointFormatStyle<Double>.Currency(code: currency ?? "USD").precision(.fractionLength(cents ? 2 : 0))
        if sign { style = style.sign(strategy: .always()) }
        return amount.formatted(style)
    }

    static func percent(_ p: Double?) -> String {
        guard let p else { return "" }
        return (p / 100).formatted(.percent.precision(.fractionLength(2)).sign(strategy: .always()))
    }
}
