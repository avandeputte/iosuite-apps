import Foundation

// What the widgets and Siri read from the start page (`/dav/ext/today`, `/dav/ext/calendars`, in the iosuite repo
// iostart/app/bookmarkext.py). Every field is optional and a field of the wrong kind reads as missing: the parts
// come from ioCalendar and ioTask, which may be older or newer than this app, or down (then the part is null).

/// An id as the apps send it: a number or a string. It goes back to the start page as it came.
enum SuiteID: Codable, Hashable, CustomStringConvertible {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i) } else { self = .string(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }

    var description: String {
        switch self {
        case .int(let i): return String(i)
        case .string(let s): return s
        }
    }

    /// Back from its description (an App Intents entity id is a string).
    init(_ text: String) { self = Int(text).map(SuiteID.int) ?? .string(text) }
}

/// Decodes what is there and of the right kind; nil for the rest.
private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ key: Key) -> T? { (try? decodeIfPresent(T.self, forKey: key)) ?? nil }
}

/// An event of ioCalendar as the start page's tile has it.
struct Occurrence: Codable, Hashable {
    var title: String?
    var start: String?
    var end: String?
    var allDay: Bool?
    var location: String?
    var color: String?
    var calendar: String?

    init(title: String? = nil, start: String? = nil, end: String? = nil, allDay: Bool? = nil, location: String? = nil, color: String? = nil, calendar: String? = nil) {
        self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.location = location; self.color = color; self.calendar = calendar
    }

    enum CodingKeys: String, CodingKey { case title, start, end, allDay, location, color, calendar }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lenient(.title); start = c.lenient(.start); end = c.lenient(.end); allDay = c.lenient(.allDay)
        location = c.lenient(.location); color = c.lenient(.color); calendar = c.lenient(.calendar)
    }

    var name: String { (title?.isEmpty == false ? title : nil) ?? "(no title)" }
    var isAllDay: Bool { allDay ?? false }
    var startDate: Date? { SuiteDate.parse(start) }
    var endDate: Date? {
        if let e = SuiteDate.parse(end) { return e }
        guard let s = startDate else { return nil }
        return isAllDay ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: s)) : s.addingTimeInterval(3600)
    }
    /// Over at `now` (an all-day event lasts its day).
    func isOver(at now: Date) -> Bool {
        guard let e = endDate else { return false }
        return e <= now
    }
}

struct TodayEvents: Codable, Hashable {
    var today: [Occurrence]?
    var more: Int?
    var next: Occurrence?

    enum CodingKeys: String, CodingKey { case today, more, next }
    init(today: [Occurrence]? = nil, more: Int? = nil, next: Occurrence? = nil) { self.today = today; self.more = more; self.next = next }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        today = c.lenient(.today); more = c.lenient(.more); next = c.lenient(.next)
    }
}

struct WeekDay: Codable, Hashable {
    var date: String?
    var items: [Occurrence]?

    enum CodingKeys: String, CodingKey { case date, items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.lenient(.date); items = c.lenient(.items)
    }
}

struct WeekEvents: Codable, Hashable {
    var days: [WeekDay]?
    var more: Int?

    enum CodingKeys: String, CodingKey { case days, more }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = c.lenient(.days); more = c.lenient(.more)
    }
}

/// A task of ioTask due today or late.
struct DueTask: Codable, Hashable {
    var id: SuiteID?
    var title: String?
    var due: String?
    var allDay: Bool?
    var late: Bool?
    var color: String?

    init(id: SuiteID? = nil, title: String? = nil, due: String? = nil, allDay: Bool? = nil, late: Bool? = nil, color: String? = nil) {
        self.id = id; self.title = title; self.due = due; self.allDay = allDay; self.late = late; self.color = color
    }

    enum CodingKeys: String, CodingKey { case id, title, due, allDay, late, color }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id); title = c.lenient(.title); due = c.lenient(.due); allDay = c.lenient(.allDay)
        late = c.lenient(.late); color = c.lenient(.color)
    }

    var name: String { (title?.isEmpty == false ? title : nil) ?? "(no title)" }
    var isLate: Bool { late ?? false }
}

struct TodayTasks: Codable, Hashable {
    var today: [DueTask]?
    var more: Int?
    var overdue: Int?

    enum CodingKeys: String, CodingKey { case today, more, overdue }
    init(today: [DueTask]? = nil, more: Int? = nil, overdue: Int? = nil) { self.today = today; self.more = more; self.overdue = overdue }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        today = c.lenient(.today); more = c.lenient(.more); overdue = c.lenient(.overdue)
    }
}

struct SuiteLinks: Codable, Hashable {
    var iocalendar: String?
    var iotask: String?
    var iocontact: String?
    var iomoney: String?

    enum CodingKeys: String, CodingKey { case iocalendar, iotask, iocontact, iomoney }
    init(iocalendar: String? = nil, iotask: String? = nil) { self.iocalendar = iocalendar; self.iotask = iotask }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iocalendar = c.lenient(.iocalendar); iotask = c.lenient(.iotask); iocontact = c.lenient(.iocontact); iomoney = c.lenient(.iomoney)
    }
}

/// The open tasks of the six days after today (`tasksWeek`).
struct WeekTasks: Codable, Hashable {
    var week: [DueTask]?
    var more: Int?

    enum CodingKeys: String, CodingKey { case week, more }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        week = c.lenient(.week); more = c.lenient(.more)
    }
}

/// A birthday or another date of ioContact, `inDays` days from today.
struct ComingDate: Codable, Hashable {
    var id: SuiteID?
    var name: String?
    var label: String?
    var turns: Int?
    var inDays: Int?
    var date: String?

    enum CodingKeys: String, CodingKey { case id, name, label, turns, inDays = "in", date }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id); name = c.lenient(.name); label = c.lenient(.label); turns = c.lenient(.turns)
        inDays = c.lenient(.inDays); date = c.lenient(.date)
    }

    var isBirthday: Bool { (label ?? "birthday") == "birthday" }
}

struct ComingDates: Codable, Hashable {
    var items: [ComingDate]?

    enum CodingKeys: String, CodingKey { case items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.lenient(.items)
    }
}

/// ioMoney's week: the payments due, the cash accounts about to run low, the bank links that are behind.
struct WeekBills: Codable, Hashable {
    struct Bill: Codable, Hashable {
        var day: String?
        var name: String?
        var amount: Double?
        var currency: String?
        var approximate: Bool?
        var account: String?

        enum CodingKeys: String, CodingKey { case day, name, amount, currency, approximate, account }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            day = c.lenient(.day); name = c.lenient(.name); amount = c.lenient(.amount); currency = c.lenient(.currency)
            approximate = c.lenient(.approximate); account = c.lenient(.account)
        }
    }
    struct Low: Codable, Hashable {
        var name: String?
        var currency: String?
        var belowOn: String?

        enum CodingKeys: String, CodingKey { case name, currency, belowOn }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.lenient(.name); currency = c.lenient(.currency); belowOn = c.lenient(.belowOn)
        }
    }
    struct Behind: Codable, Hashable {
        var name: String?
        var institution: String?

        enum CodingKeys: String, CodingKey { case name, institution }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.lenient(.name); institution = c.lenient(.institution)
        }
    }

    var currency: String?
    var bills: [Bill]?
    var more: Int?
    var total: Double?
    var low: [Low]?
    var behind: [Behind]?

    enum CodingKeys: String, CodingKey { case currency, bills, more, total, low, behind }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currency = c.lenient(.currency); bills = c.lenient(.bills); more = c.lenient(.more); total = c.lenient(.total)
        low = c.lenient(.low); behind = c.lenient(.behind)
    }
}

/// What the person's Today card shows on the start page (Customize): the parts left out, and how many of the coming
/// days its list goes (nil: the week).
struct TodayShow: Codable, Hashable {
    var off: [String]?
    var days: Int?

    enum CodingKeys: String, CodingKey { case off, days }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        off = c.lenient(.off); days = c.lenient(.days)
    }
}

/// The answer to ticking a task off: `undo` is the step that takes exactly this tick back; `moved`: a repeating
/// task went on to its next time instead.
struct Ticked: Codable {
    var moved: Bool?
    var undo: String?
    enum CodingKeys: String, CodingKey { case moved, undo }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        moved = c.lenient(.moved); undo = c.lenient(.undo)
    }
}

/// The answer of GET /dav/ext/today.
struct TodayData: Codable, Hashable {
    var today: TodayEvents?
    var week: WeekEvents?
    var tasks: TodayTasks?
    var links: SuiteLinks?
    var errors: [String: String]?
    // the Today screen's own (a start page from before it leaves them out)
    var tasksWeek: WeekTasks?
    var birthdays: ComingDates?
    var bills: WeekBills?
    var show: TodayShow?

    enum CodingKeys: String, CodingKey { case today, week, tasks, links, errors, tasksWeek, birthdays, bills, show }
    init(today: TodayEvents? = nil, week: WeekEvents? = nil, tasks: TodayTasks? = nil, links: SuiteLinks? = nil, errors: [String: String]? = nil) {
        self.today = today; self.week = week; self.tasks = tasks; self.links = links; self.errors = errors
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        today = c.lenient(.today); week = c.lenient(.week); tasks = c.lenient(.tasks); links = c.lenient(.links); errors = c.lenient(.errors)
        tasksWeek = c.lenient(.tasksWeek); birthdays = c.lenient(.birthdays); bills = c.lenient(.bills); show = c.lenient(.show)
    }

    /// Whether the person kept this part (events, tasks, birthdays, bills) on their Today card.
    func shows(_ part: String) -> Bool { !(show?.off ?? []).contains(part) }

    /// Today's events that are not over at `now` (the answer may be an hour old), in the start page's order.
    func events(at now: Date) -> [Occurrence] {
        (today?.today ?? []).filter { !$0.isOver(at: now) }
    }

    /// The event that comes next: the first timed one of today not over yet, else today's all-day one, else the next
    /// one after today (from the answer's `next`, or the week).
    func nextEvent(at now: Date) -> Occurrence? {
        let left = events(at: now)
        if let timed = left.first(where: { !$0.isAllDay }) { return timed }
        if let n = today?.next, !n.isOver(at: now) { return n }
        if let first = left.first { return first }
        return week?.days?.lazy.compactMap { $0.items?.first }.first
    }

    /// The events of today the answer did not list (`more`), while none of the listed ones is over yet: after that
    /// they may well be over too, so they are not counted.
    func moreToday(at now: Date) -> Int {
        let listed = today?.today ?? []
        return events(at: now).count == listed.count ? (today?.more ?? 0) : 0
    }

    var dueTasks: [DueTask] { tasks?.today ?? [] }
    var lateCount: Int { tasks?.overdue ?? dueTasks.filter(\.isLate).count }
    var taskCount: Int { dueTasks.count + (tasks?.more ?? 0) }

    /// Where a task opens in ioTask (the suite's href, `#/task/<id>`), else ioTask itself.
    func url(for task: DueTask) -> URL? {
        guard let base = links?.iotask?.trimmingSlash, !base.isEmpty else { return nil }
        if let id = task.id { return URL(string: base + "/#/task/" + id.description) }
        return URL(string: base)
    }

    /// Where an event opens: ioCalendar on its day (the tile's events carry no id).
    func url(for event: Occurrence?) -> URL? {
        guard let base = links?.iocalendar?.trimmingSlash, !base.isEmpty else { return nil }
        if let day = event?.start?.prefix(10), day.count == 10 { return URL(string: base + "/#/day/" + day) }
        return URL(string: base)
    }

    /// Where a birthday opens: the person in ioContact.
    func url(for date: ComingDate) -> URL? {
        guard let base = links?.iocontact?.trimmingSlash, !base.isEmpty else { return nil }
        if let id = date.id { return URL(string: base + "/#/c/" + id.description) }
        return URL(string: base)
    }

    var moneyURL: URL? { links?.iomoney.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
    var calendarURL: URL? { links?.iocalendar.flatMap { URL(string: $0) } }
    var tasksURL: URL? { links?.iotask.flatMap { URL(string: $0) } }
}

private extension String {
    var trimmingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}

/// The answer of GET /dav/ext/calendars.
struct Calendars: Codable {
    struct Entry: Codable, Hashable {
        var id: SuiteID?
        var name: String?
        var color: String?
        enum CodingKeys: String, CodingKey { case id, name, color }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lenient(.id); name = c.lenient(.name); color = c.lenient(.color)
        }
    }
    var calendars: [Entry]?
    var lists: [Entry]?

    enum CodingKeys: String, CodingKey { case calendars, lists }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calendars = c.lenient(.calendars); lists = c.lenient(.lists)
    }
}

/// The answer to adding a task or an event.
struct Added: Codable {
    var id: SuiteID?
    var url: String?
    enum CodingKeys: String, CodingKey { case id, url }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id); url = c.lenient(.url)
    }
}

/// Dates as the apps write them: "2026-11-21" (a day, here), "2026-11-21T17:00" (a time, here), or with seconds,
/// fractions and an offset or Z.
enum SuiteDate {
    static func parse(_ text: String?) -> Date? {
        guard let t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t.count == 10 { return day.date(from: t) }
        let iso = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = opts
            if let d = iso.date(from: t) { return d }
        }
        for f in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = f
            if let d = local.date(from: t) { return d }
        }
        return nil
    }

    /// "2026-11-21", in this phone's calendar.
    static func dayString(_ d: Date) -> String { day.string(from: d) }

    /// "2026-11-21T17:00:00+01:00": a time with this phone's offset.
    static func timeString(_ d: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        iso.formatOptions = [.withInternetDateTime]
        return iso.string(from: d)
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let local: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        return f
    }()
}

/// The last answer of /dav/ext/today, kept in the app group (the widgets show it when the start page cannot be reached).
enum TodayCache {
    struct Kept: Codable { var at: Date; var data: TodayData }

    static func load() -> Kept? {
        guard let data = try? Data(contentsOf: Shared.todayFile) else { return nil }
        return try? JSONDecoder().decode(Kept.self, from: data)
    }

    static func save(_ today: TodayData) {
        guard let data = try? JSONEncoder().encode(Kept(at: Date(), data: today)) else { return }
        try? data.write(to: Shared.todayFile, options: .atomic)
    }
}

extension APIError {
    /// An error of the widgets' and Siri's calls as it should be told: a start page from before them answers 404.
    static func told(_ error: Error) -> String {
        if case APIError.server(404, _) = error { return "Your start page needs an update for widgets and Siri." }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
