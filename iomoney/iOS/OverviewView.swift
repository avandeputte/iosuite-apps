import Charts
import SwiftUI

/// The net worth, now and over time, and the accounts in their five groups.
struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var span = Span.year
    @State private var history: [NetWorth.Point] = []
    @State private var warnings: [ForecastWarning] = []

    var body: some View {
        NavigationStack {
            List {
                if let s = model.summary {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Net worth").font(.subheadline).foregroundStyle(.secondary)
                            Text(Money.text(s.netWorth.netWorth, s.currency, cents: false)).font(.largeTitle.bold()).monospacedDigit()
                            change(s)
                            ValueChart(points: history.map { ($0.date, $0.value) }, currency: s.currency)
                                .frame(height: 170)
                            Picker("Period", selection: $span) {
                                ForEach(Span.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            HStack {
                                Text("Owned \(Money.text(s.netWorth.assets, s.currency, cents: false))")
                                Spacer()
                                Text("Owed \(Money.text(s.netWorth.liabilities, s.currency, cents: false))")
                            }
                            .font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    notices(s)
                    ForEach(s.groups, id: \.group) { g in
                        let rows = model.accounts.filter { $0.group == g.group && !$0.closed }
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { a in
                                    NavigationLink(value: a) { AccountRow(account: a, home: s.currency) }
                                }
                            } header: {
                                HStack {
                                    Text(g.label)
                                    Spacer()
                                    Text(Money.text(rows.filter(\.inNetWorth).map(\.value).reduce(0, +), s.currency, cents: false))
                                }
                            }
                        }
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Overview")
            .navigationDestination(for: MoneyAccount.self) { AccountView(account: $0) }
            .navigationDestination(for: API.Query.self) { TransactionsScreen(query: $0) }
            .refreshable {
                await model.refresh(quiet: false)
                await load()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .task(id: "\(span.rawValue)-\(model.credential?.password ?? "")-\(model.locked)") { await load() }
        }
    }

    @ViewBuilder
    private func change(_ s: Summary) -> some View {
        if let first = history.first, history.count > 1 {
            let d = s.netWorth.netWorth - first.value
            Text("\(Money.text(d, s.currency, cents: false, sign: true)) since \(first.date.formatted(.dateTime.day().month(.abbreviated).year()))")
                .font(.footnote).foregroundStyle(d >= 0 ? Color.green : Color.red)
        }
    }

    @ViewBuilder
    private func notices(_ s: Summary) -> some View {
        let stale = s.monarch?.stale ?? []
        if !stale.isEmpty || !warnings.isEmpty || s.review > 0 {
            Section {
                ForEach(stale) { a in
                    if let account = model.accounts.first(where: { $0.id == a.id }) {
                        NavigationLink(value: account) { staleRow(a) }
                    } else {
                        staleRow(a)
                    }
                }
                ForEach(warnings) { w in
                    if let account = model.accounts.first(where: { $0.id == w.accountId }) {
                        NavigationLink(value: account) { lowRow(w) }
                    } else {
                        lowRow(w)
                    }
                }
                if s.review > 0 {
                    NavigationLink(value: API.Query(review: true)) {
                        Label("\(s.review) transaction\(s.review == 1 ? " needs" : "s need") a look", systemImage: "eye")
                    }
                }
            }
        }
    }

    private func staleRow(_ a: Summary.Stale) -> some View {
        Label {
            VStack(alignment: .leading) {
                Text("\(a.name): its bank link is behind")
                if let why = a.why { Text(why).font(.footnote).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func lowRow(_ w: ForecastWarning) -> some View {
        Label {
            VStack(alignment: .leading) {
                Text("\(w.name) is about to run low")
                if let low = w.low {
                    Text("\(Money.text(low.value, w.currency)) on \(Day.label(low.day))").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "arrow.down.right.circle.fill").foregroundStyle(.red)
        }
    }

    private func load() async {
        guard let api = model.api, !model.locked else { return }
        do {
            history = try await api.netWorth(days: span.rawValue).history ?? []
            warnings = (try? await api.forecastWarnings()) ?? []
        } catch {
            model.failed(error, quiet: true)
        }
    }
}

struct AccountRow: View {
    let account: MoneyAccount
    let home: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(account.name)
                    if !account.household { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                    if account.bank?.stale != nil { Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                }
                if !account.detail.isEmpty { Text(account.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Text(Money.text(account.isAsset ? account.balance : -account.balance, account.currency)).monospacedDigit()
        }
    }
}

/// A value day by day, as a line over its area.
struct ValueChart: View {
    let points: [(Date, Double)]
    let currency: String
    var floor: Double?

    var body: some View {
        let values = points.map(\.1) + (floor.map { [$0] } ?? [])
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max((high - low) * 0.08, abs(high) * 0.002, 1)
        let long = (points.last?.0.timeIntervalSince(points.first?.0 ?? Date()) ?? 0) > 200 * 86400
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("Day", p.0), yStart: .value("Low", low - pad), yEnd: .value("Value", p.1))
                    .foregroundStyle(.linearGradient(colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Day", p.0), y: .value("Value", p.1))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let floor {
                RuleMark(y: .value("Lowest", floor)).foregroundStyle(.red.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartYScale(domain: (low - pad)...(high + pad))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(d.formatted(.number.notation(.compactName))) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: long ? .dateTime.month(.abbreviated).year(.twoDigits) : .dateTime.day().month(.abbreviated))
            }
        }
        .overlay { if points.count < 2 { Text("Not enough days yet").font(.footnote).foregroundStyle(.secondary) } }
    }
}
