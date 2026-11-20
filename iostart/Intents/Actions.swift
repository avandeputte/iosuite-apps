import AppIntents
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

// The Shortcuts actions, which Siri runs too (see ioStartShortcuts in the app for the phrases). Adding a task or an
// event goes to ioTask and ioCalendar through the start page (/dav/ext/tasks, /dav/ext/events) with the app's own
// sign-in, which must be a full one (Settings › Sign in again for an older, sync-only one).

struct AddTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a task"
    static var description = IntentDescription("Adds a task to ioTask through your start page.")

    @Parameter(title: "Title", requestValueDialog: "What's the task?")
    var title: String

    @Parameter(title: "Due", kind: .date)
    var due: Date?

    @Parameter(title: "List")
    var list: TaskListEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) to ioTask") {
            \.$due
            \.$list
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw $title.needsValueError("What's the task?") }
        let task = API.NewTask(title: name, due: due.map(SuiteDate.dayString), listId: list.map { SuiteID($0.id) },
                               timezone: TimeZone.current.identifier)
        let added = try await SuiteAccess.run { try await $0.addTask(task) }
        reloadWidgets()
        var said = "Added “\(name)” to ioTask"
        if let due { said += ", due " + Spoken.day(due) }
        if let list { said += ", in \(list.name)" }
        return .result(value: added.url ?? "", dialog: IntentDialog(stringLiteral: said + "."))
    }
}

struct AddEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Add an event"
    static var description = IntentDescription("Adds an event to ioCalendar through your start page. Without an end, it lasts an hour (all day: the day).")

    @Parameter(title: "Title", requestValueDialog: "What's the event?")
    var title: String

    @Parameter(title: "Start", requestValueDialog: "When does it start?")
    var start: Date

    @Parameter(title: "End")
    var end: Date?

    @Parameter(title: "All day", default: false)
    var allDay: Bool

    @Parameter(title: "Calendar")
    var calendar: CalendarEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) on \(\.$start) to ioCalendar") {
            \.$end
            \.$allDay
            \.$calendar
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw $title.needsValueError("What's the event?") }
        if let end, end < start { throw IntentProblem(message: "The event would end before it starts.") }
        let event = API.NewEvent(
            title: name,
            start: allDay ? SuiteDate.dayString(start) : SuiteDate.timeString(start),
            // an all-day event's end is the day after its last one, as in iCalendar
            end: end.map { allDay ? SuiteDate.dayString(Calendar.current.date(byAdding: .day, value: 1, to: $0) ?? $0) : SuiteDate.timeString($0) },
            allDay: allDay, timezone: TimeZone.current.identifier, calendarId: calendar.map { SuiteID($0.id) })
        let added = try await SuiteAccess.run { try await $0.addEvent(event) }
        reloadWidgets()
        var said = "Added “\(name)” to ioCalendar, " + Spoken.day(start)
        if !allDay { said += " at " + start.formatted(date: .omitted, time: .shortened) }
        if let calendar { said += ", in \(calendar.name)" }
        return .result(value: added.url ?? "", dialog: IntentDialog(stringLiteral: said + "."))
    }
}

struct ShowTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "Show today"
    static var description = IntentDescription("Says what is on today in ioCalendar and what is due in ioTask.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let today = try await SuiteAccess.run { try await $0.today() }
        TodayCache.save(today)
        let said = Spoken.summary(today, at: Date())
        return .result(value: said, dialog: IntentDialog(stringLiteral: said))
    }
}

struct OpenBookmarkIntent: AppIntent {
    static var title: LocalizedStringResource = "Open bookmark"
    static var description = IntentDescription("Opens one of your bookmarks in ioStart.")
    static var openAppWhenRun = true

    @Parameter(title: "Bookmark", requestValueDialog: "Which bookmark?")
    var bookmark: BookmarkEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$bookmark)")
    }

    init() {}
    init(bookmark: BookmarkEntity) { self.bookmark = bookmark }

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLink.pending = .bookmark(bookmark.id)
        NotificationCenter.default.post(name: .ioStartOpenLink, object: nil)
        return .result()
    }
}

private func reloadWidgets() {
    #if canImport(WidgetKit)
    WidgetCenter.shared.reloadAllTimelines()
    #endif
}

/// How Siri says a day and a summary of today.
enum Spoken {
    static func day(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "today" }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "tomorrow" }
        if let week = cal.date(byAdding: .day, value: 6, to: now), d > now, d < week {
            return d.formatted(.dateTime.weekday(.wide))
        }
        return d.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    static func time(_ o: Occurrence) -> String {
        guard !o.isAllDay, let s = o.startDate else { return "all day" }
        return "at " + s.formatted(date: .omitted, time: .shortened)
    }

    static func summary(_ t: TodayData, at now: Date) -> String {
        var parts: [String] = []
        if t.today == nil && t.week == nil {
            parts.append("ioCalendar did not answer.")
        } else {
            let left = t.events(at: now)
            if left.isEmpty {
                if let next = t.nextEvent(at: now), let s = next.startDate {
                    parts.append("Nothing more on your calendar today. Next: \(next.name), \(day(s, now: now)) \(time(next)).")
                } else {
                    parts.append("Nothing more on your calendar today.")
                }
            } else {
                let more = t.moreToday(at: now)
                let n = left.count + more
                let list = left.prefix(4).map { "\($0.name) \(time($0))" }.joined(separator: ", ")
                parts.append("\(n == 1 ? "One event" : "\(n) events") left today: \(list)\(n > 4 ? ", and more" : "").")
            }
        }
        if t.tasks == nil {
            parts.append("ioTask did not answer.")
        } else {
            let n = t.taskCount
            let late = t.lateCount
            if n == 0 {
                parts.append("No tasks due.")
            } else {
                let names = t.dueTasks.prefix(3).map(\.name).joined(separator: ", ")
                parts.append("\(n == 1 ? "One task" : "\(n) tasks") due\(late > 0 ? ", \(late) late" : ""): \(names)\(n > 3 ? ", and more" : "").")
            }
        }
        return parts.joined(separator: " ")
    }
}
