import Foundation
import WidgetKit

/// What the Today and Next event widgets show.
enum TodayState {
    /// The day as the start page told it; `kept`: an older answer, the start page could not be reached just now.
    case day(TodayData, kept: Date?)
    case signedOut
    case failed(String)
}

struct TodayEntry: TimelineEntry {
    let date: Date
    let state: TodayState
}

/// Asks the start page for the day (`/dav/ext/today`) about every 20 minutes, and redraws when an event ends, so
/// what is over leaves the widget without waiting for the next answer.
struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), state: .day(.sample(), kept: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        if context.isPreview {
            if let kept = TodayCache.load() { return completion(TodayEntry(date: Date(), state: .day(kept.data, kept: nil))) }
            return completion(placeholder(in: context))
        }
        Task { completion(TodayEntry(date: Date(), state: await TodayProvider.load())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        Task {
            let now = Date()
            let state = await TodayProvider.load()
            var dates = [now]
            if case .day(let data, _) = state {
                // every moment in the next few hours when an event of today ends or starts
                let soon = now.addingTimeInterval(4 * 3600)
                let marks = (data.today?.today ?? []).flatMap { [$0.startDate, $0.endDate] }.compactMap { $0 }
                dates += Set(marks.filter { $0 > now && $0 < soon }).sorted().prefix(12)
            }
            let entries = dates.map { TodayEntry(date: $0, state: state) }
            let again: Date
            switch state {
            case .day(_, let kept): again = now.addingTimeInterval(kept == nil ? 20 * 60 : 10 * 60)
            case .failed: again = now.addingTimeInterval(10 * 60)
            case .signedOut: again = now.addingTimeInterval(60 * 60)
            }
            completion(Timeline(entries: entries, policy: .after(again)))
        }
    }

    static func load() async -> TodayState {
        WidgetNetwork.setUp()
        guard let account = Account.load() else { return .signedOut }
        do {
            let data = try await API(account: account).today()
            TodayCache.save(data)
            return .day(data, kept: nil)
        } catch APIError.signedOut {
            return .signedOut
        } catch {
            if let kept = TodayCache.load(), kept.at > Date().addingTimeInterval(-36 * 3600) {
                return .day(kept.data, kept: kept.at)
            }
            return .failed(APIError.told(error))
        }
    }
}

enum WidgetNetwork {
    /// A widget gets a few seconds for its timeline: no waiting a minute for a network.
    static func setUp() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 15
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        API.session = URLSession(configuration: c)
    }
}

extension TodayData {
    /// What the widget gallery and the placeholder show.
    static func sample(now: Date = Date()) -> TodayData {
        let cal = Calendar.current
        func at(_ h: Int, _ m: Int = 0) -> String {
            SuiteDate.timeString(cal.date(bySettingHour: h, minute: m, second: 0, of: now) ?? now)
        }
        return TodayData(
            today: TodayEvents(today: [
                Occurrence(title: "Swimming lesson", start: at(16, 30), end: at(17, 30), location: "Pool", color: "#3b82f6"),
                Occurrence(title: "Dinner with Sam", start: at(19), end: at(21), color: "#f97316"),
                Occurrence(title: "Call the plumber", start: at(21, 30), end: at(22), color: "#10b981"),
            ], more: 0),
            tasks: TodayTasks(today: [
                DueTask(id: .int(1), title: "Renew the library books", late: true, color: "#ef4444"),
                DueTask(id: .int(2), title: "Buy birthday card", color: "#8b5cf6"),
                DueTask(id: .int(3), title: "Water the plants", color: "#10b981"),
            ], more: 0, overdue: 1),
            links: SuiteLinks(iocalendar: "https://calendar.example.com", iotask: "https://tasks.example.com"))
    }
}
