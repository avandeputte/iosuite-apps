import SwiftUI
import WidgetKit

/// A line of the Today screen: an event, a task or a birthday, with where it sorts in its day (what is late first,
/// then birthdays, all-day events, then by the hour; a task without an hour last), as on the start page's Today card.
private struct DayLine: Identifiable {
    enum What {
        case event(Occurrence)
        case task(DueTask)
        case date(ComingDate)
    }
    let id: String
    let at: Double
    let what: What
}

/// What the Today screen lists, worked out from the start page's answer as its Today card does.
private struct DayPlan {
    struct Day: Identifiable {
        let id: String        // "2026-11-25"
        let date: Date
        let lines: [DayLine]
    }

    var today: [DayLine] = []
    var days: [Day] = []
    var next: Occurrence?
    var more = ""             // "+2 more today · 1 overdue"
    var none = "Nothing planned or due today"
    var hasPlans = false      // whether any of events, tasks and birthdays is there to list

    init(_ d: TodayData, now: Date) {
        let cal = d.shows("events") ? d.today : nil
        let week = d.shows("events") ? d.week : nil
        let tasks = d.shows("tasks") ? d.tasks : nil
        let tasksWeek = d.shows("tasks") ? d.tasksWeek : nil
        let showDates = d.shows("birthdays")
        let dates = showDates ? (d.birthdays?.items ?? []).filter { (0...7).contains($0.inDays ?? -1) } : []
        hasPlans = cal != nil || tasks != nil || !dates.isEmpty
        let far = d.show?.days ?? Int.max
        let dayNow = Calendar.current.startOfDay(for: now)

        func daysTo(_ day: String) -> Int? {
            guard let date = SuiteDate.parse(String(day.prefix(10))) else { return nil }
            return Calendar.current.dateComponents([.day], from: dayNow, to: Calendar.current.startOfDay(for: date)).day
        }
        // ioCalendar's Birthdays calendar has the birthdays too ("Ava Calloway's birthday"): left to ioContact's
        // line when there is one, and gone with the birthdays switched off
        func mine(_ items: [Occurrence], _ n: Int) -> [Occurrence] {
            items.filter { o in
                guard o.isAllDay, o.name.range(of: #"\b(birthday|anniversary)\b"#, options: [.regularExpression, .caseInsensitive]) != nil else { return true }
                return showDates && !dates.contains { $0.inDays == n && o.name.contains($0.name ?? "\u{0}") }
            }
        }
        func line(_ o: Occurrence, _ key: String) -> DayLine {
            DayLine(id: "e-\(key)-\(o.start ?? "")-\(o.name)", at: o.isAllDay ? 0 : (o.startDate?.timeIntervalSince1970 ?? 0), what: .event(o))
        }
        func line(_ t: DueTask) -> DayLine {
            let hour = (t.allDay ?? true) ? nil : SuiteDate.parse(t.due)
            return DayLine(id: "t-\(t.id?.description ?? t.name)", at: t.isLate ? -1 : (hour?.timeIntervalSince1970 ?? .infinity), what: .task(t))
        }
        func line(_ b: ComingDate) -> DayLine {
            DayLine(id: "d-\(b.id?.description ?? "")-\(b.name ?? "")-\(b.label ?? "")", at: -0.5, what: .date(b))
        }
        func sorted(_ lines: [DayLine]) -> [DayLine] {
            lines.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        }

        let events = mine(cal?.today ?? [], 0)
        today = sorted(dates.filter { $0.inDays == 0 }.map(line) + (tasks?.today ?? []).map(line) + events.map { line($0, "0") })
        none = cal != nil && tasks != nil ? "Nothing planned or due today" : cal != nil ? "Nothing planned today" : tasks != nil ? "Nothing due today" : "No birthdays today"

        var ahead: [String: [DayLine]] = [:]
        func on(_ day: String, _ l: DayLine) {
            guard let n = daysTo(day), n > 0, n <= far else { return }
            ahead[String(day.prefix(10)), default: []].append(l)
        }
        for b in dates where (b.inDays ?? 0) > 0 {
            if let day = Calendar.current.date(byAdding: .day, value: b.inDays ?? 0, to: dayNow) { on(SuiteDate.dayString(day), line(b)) }
        }
        for day in week?.days ?? [] {
            guard let date = day.date, let n = daysTo(date) else { continue }
            for o in mine(day.items ?? [], n) { on(date, line(o, date)) }
        }
        for t in tasksWeek?.week ?? [] {
            guard let due = t.due else { continue }
            let timed = !(t.allDay ?? true) && SuiteDate.parse(due) != nil
            on(timed ? SuiteDate.dayString(SuiteDate.parse(due)!) : String(due.prefix(10)), line(t))
        }
        days = ahead.keys.sorted().compactMap { key in
            SuiteDate.parse(key).map { Day(id: key, date: $0, lines: sorted(ahead[key] ?? [])) }
        }
        // nothing today and nothing in the days listed: the next event, however far off
        if cal != nil, events.isEmpty, days.isEmpty, far > 0, let n = cal?.next, !n.isOver(at: now) { next = n }

        let moreToday = (cal?.more ?? 0) + (tasks?.more ?? 0)
        let late = tasks?.overdue ?? 0
        more = [moreToday > 0 ? "+\(moreToday) more today" : nil, late > 0 ? "\(late) overdue" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The day as the start page's Today card has it: events, tasks to tick off and birthdays of today and the coming
/// days, and the week's bills. What the person switched off on the page (Customize) is left out here too.
struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var news: NewsModel
    @Environment(\.scenePhase) private var phase
    /// The app's tab: the two buttons on top go to the news and the bookmarks.
    @Binding var tab: String

    @State private var data: TodayData?
    @State private var keptAt: Date?
    @State private var problem: String?
    @State private var loading = false
    @State private var ticked: [String: String?] = [:]   // a task's id: the step that takes its tick back
    @State private var note: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Today")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                    }
                }
                .refreshable { await load() }
        }
        .task {
            if data == nil, let kept = TodayCache.load() {
                data = kept.data
                keptAt = kept.at
            }
            await news.refresh(model.account)  // the unread count on the News button
            await load()
        }
        .onChange(of: phase) { _, now in
            if now == .active { Task { await load() } }
        }
    }

    @ViewBuilder private var content: some View {
        if let data {
            list(data, DayPlan(data, now: Date()))
        } else {
            // the two buttons stay, whatever the day's answer
            List {
                doors
                Section {
                    if let problem {
                        VStack(spacing: 10) {
                            Label("Today is not available", systemImage: "calendar.badge.exclamationmark").font(.headline)
                            Text(problem).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Try again") { Task { await load() } }.buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    } else {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func list(_ d: TodayData, _ plan: DayPlan) -> some View {
        List {
            doors
            if let problem {
                Section {
                    Label(problem, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.secondary)
                } footer: {
                    if let keptAt { Text("Showing what the start page said \(keptAt.formatted(.relative(presentation: .named))).") }
                }
            }
            if plan.hasPlans {
                Section {
                    if plan.today.isEmpty && plan.next == nil { Text(plan.none).foregroundStyle(.secondary) }
                    ForEach(plan.today) { row($0, d) }
                    if let next = plan.next { nextRow(next, d) }
                } header: {
                    HStack {
                        Text(Date().formatted(.dateTime.weekday(.wide).month().day()))
                        Spacer()
                        if !plan.more.isEmpty { Text(plan.more) }
                    }
                } footer: {
                    if let note { Text(note) }
                }
                ForEach(plan.days) { day in
                    Section(dayName(day.date)) {
                        ForEach(day.lines) { row($0, d) }
                    }
                }
            }
            if d.shows("bills"), let bills = d.bills { billsSection(bills, d) }
            let errors = (d.errors ?? [:]).filter { d.shows(part(of: $0.key)) }
            if !errors.isEmpty {
                Section {
                    ForEach(errors.values.sorted().uniqued(), id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            if !plan.hasPlans && !(d.shows("bills") && d.bills != nil) && errors.isEmpty {
                Section { Text("Nothing to show: the Today card of your start page has everything switched off, or its apps are not there.").foregroundStyle(.secondary) }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// News and Bookmarks, side by side on top of the day: the rest of the app, one tap away.
    private var doors: some View {
        Section {
            HStack(spacing: 12) {
                door("News", "newspaper.fill", news.loaded ? (news.overview.unread > 0 ? "\(news.overview.unread) unread" : "Nothing new") : "Your feeds", to: "news")
                door("Bookmarks", "bookmark.fill", model.loaded ? "\(model.tree.linkCount) links" : "Your links", to: "bookmarks")
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func door(_ name: String, _ icon: String, _ detail: String, to: String) -> some View {
        Button { tab = to } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(detail)")
    }

    /// The switch of the Today card a part of the answer goes with.
    private func part(of key: String) -> String {
        switch key {
        case "today", "week": return "events"
        case "tasks", "tasksWeek": return "tasks"
        default: return key
        }
    }

    private func dayName(_ date: Date) -> String {
        let name = Calendar.current.isDateInTomorrow(date) ? "Tomorrow" : date.formatted(.dateTime.weekday(.wide))
        return name + " · " + date.formatted(.dateTime.month().day())
    }

    // MARK: rows

    @ViewBuilder private func row(_ line: DayLine, _ d: TodayData) -> some View {
        switch line.what {
        case .event(let o): eventRow(o, d)
        case .task(let t): taskRow(t, d)
        case .date(let b): dateRow(b, d)
        }
    }

    private func time(_ date: Date?) -> String { date?.formatted(date: .omitted, time: .shortened) ?? "" }

    /// What comes before the first comma of an event's place.
    private func shortPlace(_ loc: String?) -> String? {
        let t = (loc ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let first = t.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return first.isEmpty ? (t.isEmpty ? nil : t) : first
    }

    private func eventRow(_ o: Occurrence, _ d: TodayData) -> some View {
        Button { if let url = d.url(for: o) { model.open(url) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(Color(hex: o.color) ?? .secondary).frame(width: 9, height: 9)
                Text(o.isAllDay ? "All day" : time(o.startDate)).font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 70, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.name).foregroundStyle(.primary)
                    if let place = shortPlace(o.location) { Text(place).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func nextRow(_ o: Occurrence, _ d: TodayData) -> some View {
        Button { if let url = d.url(for: o) { model.open(url) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(Color(hex: o.color) ?? .secondary).frame(width: 9, height: 9)
                Text("Next").font(.callout).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.name).foregroundStyle(.primary)
                    if let s = o.startDate {
                        Text(o.isAllDay ? s.formatted(.dateTime.weekday(.wide).month().day()) : s.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func taskRow(_ t: DueTask, _ d: TodayData) -> some View {
        let key = t.id?.description ?? ""
        let done = ticked[key] != nil
        let hour = (t.allDay ?? true) ? nil : SuiteDate.parse(t.due)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { Task { await tick(t) } } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(Color(hex: t.color) ?? .secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(t.id == nil)
            .accessibilityLabel(done ? "Not done after all: \(t.name)" : "Done: \(t.name)")
            Button { if let url = d.url(for: t) { model.open(url) } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(t.name).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                    Spacer(minLength: 0)
                    if t.isLate {
                        Text("Late").font(.footnote.weight(.medium)).foregroundStyle(.orange)
                    } else if let hour {
                        Text(time(hour)).font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func dateRow(_ b: ComingDate, _ d: TodayData) -> some View {
        Button { if let url = d.url(for: b) { model.open(url) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(b.isBirthday ? "🎂" : "🎉")
                Text(b.name ?? "").foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(b.isBirthday ? (b.turns.map { "turns \($0)" } ?? "Birthday") : ((b.label ?? "") + (b.turns.map { " · \($0) years" } ?? "")))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: bills

    private func money(_ amount: Double?, _ currency: String?) -> String {
        guard let amount else { return "" }
        return abs(amount).formatted(.currency(code: currency ?? "USD"))
    }

    private func shortDay(_ iso: String?) -> String {
        guard let date = SuiteDate.parse(iso.map { String($0.prefix(10)) }) else { return "" }
        if date <= Calendar.current.startOfDay(for: Date()) || Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tmrw" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    @ViewBuilder private func billsSection(_ b: WeekBills, _ d: TodayData) -> some View {
        let bills = b.bills ?? [], low = b.low ?? [], behind = b.behind ?? []
        let count = bills.count + (b.more ?? 0)
        Section {
            if let a = low.first {
                Label(low.count > 1 ? "\(low.count) accounts run low" : "Low \(shortDay(a.belowOn).lowercased()): \(a.name ?? "")", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let a = behind.first {
                Label(behind.count > 1 ? "\(behind.count) bank links behind" : "Bank link behind: \(a.name ?? "")", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if bills.isEmpty && low.isEmpty && behind.isEmpty { Text("Nothing due").foregroundStyle(.secondary) }
            ForEach(Array(bills.enumerated()), id: \.offset) { _, bill in
                Button { if let url = d.moneyURL { model.open(url) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(shortDay(bill.day)).font(.callout).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .leading)
                        Text(bill.name ?? "").foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(((bill.approximate ?? false) ? "~" : "") + money(bill.amount, bill.currency ?? b.currency)).monospacedDigit().foregroundStyle(.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let more = b.more, more > 0 { Text("+\(more) more").font(.footnote).foregroundStyle(.secondary) }
        } header: {
            HStack {
                Text("Bills this week")
                Spacer()
                if count > 1, let total = b.total { Text(money(total, b.currency)) }
            }
        }
    }

    // MARK: asking and ticking

    private func load() async {
        guard let account = model.account, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let fresh = try await API(account: account).today()
            data = fresh
            keptAt = nil
            problem = nil
            ticked = [:]
            TodayCache.save(fresh)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            if case APIError.signedOut = error {
                model.forget()
                model.problem = error.localizedDescription
            } else if case APIError.readOnly = error {
                problem = "Sign out and in again (Settings) to see your day here."
            } else {
                problem = APIError.told(error)
            }
        }
    }

    /// Ticks a task off at once, back when ioTask says no; a second tap takes exactly that tick back.
    private func tick(_ t: DueTask) async {
        guard let account = model.account, let id = t.id else { return }
        let key = id.description
        let api = API(account: account)
        if let step = ticked[key] {
            ticked[key] = nil
            do { _ = try await api.tick(id, done: false, undo: step) } catch {
                ticked[key] = .some(step)
                model.problem = APIError.told(error)
            }
        } else {
            ticked[key] = .some(nil)
            do {
                let r = try await api.tick(id, done: true)
                ticked[key] = .some(r.undo)
                note = (r.moved ?? false) ? "“\(t.name)” moves on to its next time." : nil
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
                ticked[key] = nil
                model.problem = APIError.told(error)
            }
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

extension Color {
    /// "#1e8e3e" (or "1e8e3e", "#abc") as a colour; nil for anything else.
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
