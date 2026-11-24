import SwiftUI
import WidgetKit

// The Today widget (the day's events, and in the larger sizes the tasks due) and the Next event widget.

struct TodayWidget: Widget {
    let kind = "net.iothing.iostart.today"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayProvider()) { entry in
            TodayView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("What is left on your calendar today, and in the larger sizes the tasks due.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct NextEventWidget: Widget {
    let kind = "net.iothing.iostart.next"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayProvider()) { entry in
            NextEventView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next event")
        .description("The next event on your calendar.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

// MARK: the pieces

extension Color {
    /// "#3b82f6", "3b82f6" or "#38f"; nil for anything else.
    init?(hex: String?) {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let rgb = h.count == 8 ? v >> 8 : v
        self.init(red: Double((rgb >> 16) & 0xff) / 255, green: Double((rgb >> 8) & 0xff) / 255, blue: Double(rgb & 0xff) / 255)
    }
}

/// When an event is: "16:30", "all day", "Tue 10:00".
func whenText(_ o: Occurrence, now: Date, withDay: Bool = false) -> String {
    let cal = Calendar.current
    guard let s = o.startDate else { return "" }
    let showDay = withDay && !cal.isDate(s, inSameDayAs: now)
    let day: String
    if !showDay { day = "" } else if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(s, inSameDayAs: t) {
        day = "Tomorrow"
    } else {
        day = s.formatted(.dateTime.weekday(.abbreviated).day())
    }
    if o.isAllDay { return showDay ? day : "All day" }
    let time = s.formatted(date: .omitted, time: .shortened)
    return showDay ? "\(day) \(time)" : time
}

private struct EventRow: View {
    let event: Occurrence
    let now: Date
    var withDay = false
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: event.color) ?? .accentColor)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.name).font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(whenText(event, now: now, withDay: withDay))
                    if !compact, let loc = event.location, !loc.isEmpty { Text("· " + loc).lineLimit(1) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TaskRow: View {
    let task: DueTask

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(hex: task.color) ?? .secondary)
            Text(task.name).font(.caption).lineLimit(1)
            Spacer(minLength: 0)
            if task.isLate { Text("Late").font(.caption2.weight(.semibold)).foregroundStyle(.red) }
        }
    }
}

/// A row that opens its page through the app (iostart://open?url=), or just the row when there is no page.
private struct Opens<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: Content

    var body: some View {
        // a Link tints what is in it with the accent colour: the rows keep their own
        if let url { Link(destination: DeepLink.page(url).url) { content.foregroundStyle(Color.primary) }.tint(Color.primary) } else { content }
    }
}

/// What a widget says instead of the day.
private struct Notice: View {
    let state: TodayState
    let family: WidgetFamily

    /// One short line, for the inline widget above the clock.
    private var inlineText: String {
        switch state {
        case .signedOut: return "Sign in to ioStart"
        case .failed: return "ioStart: no answer"
        case .day: return ""
        }
    }

    var body: some View {
        let (icon, text): (String, String) = {
            switch state {
            case .signedOut: return ("person.crop.circle.badge.questionmark", "Open ioStart and sign in.")
            case .failed(let why): return ("exclamationmark.triangle", why)
            case .day: return ("", "")
            }
        }()
        if family == .accessoryInline {
            Label(inlineText, systemImage: icon)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).font(family == .accessoryRectangular ? .caption : .title3).foregroundStyle(.secondary)
                Text(text)
                    .font(family == .accessoryRectangular ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DayHeader: View {
    let now: Date
    let kept: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(now.formatted(.dateTime.weekday(.wide))).font(.caption.weight(.bold)).foregroundStyle(.red).textCase(.uppercase)
            Text(now.formatted(.dateTime.day())).font(.caption.weight(.bold))
            Spacer(minLength: 0)
            if kept != nil { Image(systemName: "icloud.slash").font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

// MARK: Today

struct TodayView: View {
    let entry: TodayEntry
    /// Nil: the widget's own (set only to draw the widget outside WidgetKit).
    var size: WidgetFamily?
    @Environment(\.widgetFamily) private var widgetFamily
    private var family: WidgetFamily { size ?? widgetFamily }

    var body: some View {
        switch entry.state {
        case .day(let data, let kept):
            switch family {
            case .accessoryRectangular: rectangular(data)
            case .systemMedium: medium(data, kept: kept)
            case .systemLarge: large(data, kept: kept)
            default: small(data, kept: kept)
            }
        default:
            Notice(state: entry.state, family: family).widgetURL(DeepLink.settings.url)
        }
    }

    private var now: Date { entry.date }

    private func events(_ data: TodayData, _ n: Int, compact: Bool = false) -> some View {
        let left = data.events(at: now)
        let more = max(0, left.count - n) + data.moreToday(at: now)
        return VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            if data.today == nil {
                Text("ioCalendar did not answer.").font(.caption).foregroundStyle(.secondary)
            } else if left.isEmpty {
                Text("Nothing more today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let next = data.nextEvent(at: now) {
                    Opens(url: data.url(for: next)) { EventRow(event: next, now: now, withDay: true, compact: compact) }
                }
            } else {
                ForEach(Array(left.prefix(n).enumerated()), id: \.offset) { _, ev in
                    Opens(url: data.url(for: ev)) { EventRow(event: ev, now: now, compact: compact) }
                }
                if more > 0 { Text("+\(more) more").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    private func tasks(_ data: TodayData, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("Tasks").font(.caption.weight(.bold))
                if data.tasks != nil { Text("\(data.taskCount)").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if data.lateCount > 0 { Text("\(data.lateCount) late").font(.caption2.weight(.semibold)).foregroundStyle(.red) }
            }
            if data.tasks == nil {
                Text("ioTask did not answer.").font(.caption).foregroundStyle(.secondary)
            } else if data.dueTasks.isEmpty {
                Text("Nothing due").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(data.dueTasks.prefix(n).enumerated()), id: \.offset) { _, t in
                    Opens(url: data.url(for: t)) { TaskRow(task: t) }
                }
                let more = data.taskCount - min(n, data.dueTasks.count)
                if more > 0 { Text("+\(more) more").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    private func small(_ data: TodayData, kept: Date?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DayHeader(now: now, kept: kept)
            events(data, 3, compact: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(data.url(for: data.nextEvent(at: now)).map { DeepLink.page($0).url })
    }

    private func medium(_ data: TodayData, kept: Date?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                DayHeader(now: now, kept: kept)
                events(data, 3, compact: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading) {
                tasks(data, 4)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func large(_ data: TodayData, kept: Date?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DayHeader(now: now, kept: kept)
            events(data, 5)
            Divider()
            tasks(data, 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rectangular(_ data: TodayData) -> some View {
        let left = data.events(at: now)
        let next = data.nextEvent(at: now)
        return VStack(alignment: .leading, spacing: 1) {
            if let next {
                Text(next.name).font(.headline).lineLimit(1).widgetAccentable()
                Text(whenText(next, now: now, withDay: true) + (left.count > 1 ? " · +\(left.count - 1) today" : "")).font(.caption).lineLimit(1)
            } else {
                Text("Nothing on today").font(.headline).lineLimit(1)
            }
            if data.tasks != nil {
                Text(data.taskCount == 0 ? "No tasks due" : "\(data.taskCount) due" + (data.lateCount > 0 ? ", \(data.lateCount) late" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(data.url(for: next).map { DeepLink.page($0).url })
    }
}

// MARK: Next event

struct NextEventView: View {
    let entry: TodayEntry
    /// Nil: the widget's own (set only to draw the widget outside WidgetKit).
    var size: WidgetFamily?
    @Environment(\.widgetFamily) private var widgetFamily
    private var family: WidgetFamily { size ?? widgetFamily }

    var body: some View {
        switch entry.state {
        case .day(let data, let kept):
            let next = data.nextEvent(at: entry.date)
            Group {
                switch family {
                case .accessoryInline: inline(next)
                case .accessoryCircular: circular(next)
                case .accessoryRectangular: rectangular(next)
                default: small(next, kept: kept)
                }
            }
            .widgetURL(data.url(for: next).map { DeepLink.page($0).url })
        default:
            Notice(state: entry.state, family: family).widgetURL(DeepLink.settings.url)
        }
    }

    private var now: Date { entry.date }

    /// "in 25 min", "now" for one under way.
    @ViewBuilder private func soon(_ o: Occurrence) -> some View {
        if !o.isAllDay, let s = o.startDate, Calendar.current.isDate(s, inSameDayAs: now) {
            if s <= now { Text("Now") } else { Text(s, style: .relative) }
        }
    }

    private func small(_ next: Occurrence?, kept: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "calendar").foregroundStyle(Color(hex: next?.color) ?? .red)
                Text("Next").font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer(minLength: 0)
                if kept != nil { Image(systemName: "icloud.slash").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if let next {
                Text(next.name).font(.headline).lineLimit(3).minimumScaleFactor(0.8)
                Text(whenText(next, now: now, withDay: true)).font(.subheadline.weight(.semibold)).foregroundStyle(Color(hex: next.color) ?? .accentColor)
                if let loc = next.location, !loc.isEmpty { Text(loc).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                soon(next).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Nothing coming up").font(.headline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rectangular(_ next: Occurrence?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let next {
                Label { Text(whenText(next, now: now, withDay: true)) } icon: { Image(systemName: "calendar") }
                    .font(.caption.weight(.semibold)).widgetAccentable()
                Text(next.name).font(.headline).lineLimit(2)
                if let loc = next.location, !loc.isEmpty { Text(loc).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            } else {
                Text("Nothing coming up").font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ next: Occurrence?) -> some View {
        if let next {
            return Label("\(whenText(next, now: now, withDay: true)) \(next.name)", systemImage: "calendar")
        }
        return Label("Nothing coming up", systemImage: "calendar")
    }

    private func circular(_ next: Occurrence?) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "calendar").font(.caption2)
                if let next, let s = next.startDate {
                    if next.isAllDay || !Calendar.current.isDate(s, inSameDayAs: now) {
                        Text(s.formatted(.dateTime.weekday(.abbreviated))).font(.caption2.weight(.semibold))
                    } else {
                        Text(s.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())).font(.caption.weight(.semibold)).minimumScaleFactor(0.6)
                    }
                } else {
                    Text("–").font(.caption)
                }
            }
        }
        .widgetAccentable()
    }
}
