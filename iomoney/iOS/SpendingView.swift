import Charts
import SwiftUI

/// Money out and in by category for a month, and month by month over the past year (transfers left out).
struct SpendingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var month = String(Day.string(Date()).prefix(7))
    @State private var spending: Spending?
    @State private var flow: CashFlow?

    private var thisMonth: String { String(Day.string(Date()).prefix(7)) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button { step(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                        Spacer()
                        Text(Day.month(month)).font(.headline)
                        Spacer()
                        Button { step(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless).disabled(month >= thisMonth)
                    }
                    if let s = spending {
                        HStack {
                            total("Spent", s.spent, s.currency)
                            Spacer()
                            total("Income", s.income, s.currency)
                            Spacer()
                            total("Left", s.net, s.currency, colored: true)
                        }
                        .padding(.vertical, 4)
                    }
                }
                if let s = spending {
                    let out = s.categories.filter { $0.spent > 0 }
                    let top = out.map(\.spent).max() ?? 1
                    if !out.isEmpty {
                        Section("Money out") {
                            ForEach(out) { c in
                                NavigationLink(value: API.Query(category: c.category ?? "-", month: month, flow: "out")) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(c.category ?? "No category")
                                            Spacer()
                                            Text(Money.text(c.spent, s.currency)).monospacedDigit()
                                        }
                                        GeometryReader { g in
                                            Capsule().fill(Color.accentColor.opacity(0.75)).frame(width: max(3, g.size.width * c.spent / top))
                                        }
                                        .frame(height: 5)
                                        Text([c.group, "\(c.count) transaction\(c.count == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    let come = s.categories.filter { $0.income > 0 }
                    if !come.isEmpty {
                        Section("Money in") {
                            ForEach(come) { c in
                                NavigationLink(value: API.Query(category: c.category ?? "-", month: month, flow: "in")) {
                                    HStack {
                                        Text(c.category ?? "No category")
                                        Spacer()
                                        Text(Money.text(c.income, s.currency)).monospacedDigit().foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                    if out.isEmpty, come.isEmpty { Text("Nothing this month.").foregroundStyle(.secondary) }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
                if let f = flow, !f.items.isEmpty {
                    Section("Month by month") {
                        Chart {
                            ForEach(f.items) { m in
                                BarMark(x: .value("Month", Day.date(m.month + "-01"), unit: .month), y: .value("Amount", m.income))
                                    .foregroundStyle(by: .value("What", "Income")).position(by: .value("What", "Income"))
                                BarMark(x: .value("Month", Day.date(m.month + "-01"), unit: .month), y: .value("Amount", m.spent))
                                    .foregroundStyle(by: .value("What", "Spent")).position(by: .value("What", "Spent"))
                            }
                        }
                        .chartForegroundStyleScale(["Income": Color.green.opacity(0.75), "Spent": Color.accentColor])
                        .chartYAxis {
                            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let d = v.as(Double.self) { Text(d.formatted(.number.notation(.compactName))) }
                                }
                            }
                        }
                        .chartXAxis { AxisMarks(values: .stride(by: .month, count: 2)) { _ in AxisValueLabel(format: .dateTime.month(.narrow)) } }
                        .frame(height: 190)
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Spending")
            .navigationDestination(for: API.Query.self) { TransactionsScreen(query: $0) }
            .refreshable { await load() }
            .task(id: "\(month)-\(model.changes)-\(model.locked)") { await load() }
        }
    }

    private func total(_ label: String, _ value: Double, _ currency: String, colored: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(Money.text(value, currency, cents: false)).font(.headline).monospacedDigit()
                .foregroundStyle(colored ? (value >= 0 ? Color.green : Color.red) : Color.primary)
        }
    }

    private func step(_ d: Int) {
        let cal = Calendar(identifier: .gregorian)
        guard let next = cal.date(byAdding: .month, value: d, to: Day.date(month + "-01")) else { return }
        spending = nil
        month = String(Day.string(next).prefix(7))
    }

    private func load() async {
        guard let api = model.api, !model.locked else { return }
        do {
            spending = try await api.spending(month: month)
            if flow == nil || month == thisMonth { flow = try? await api.cashFlow() }
        } catch {
            if !Task.isCancelled { model.failed(error, quiet: true) }
        }
    }
}
