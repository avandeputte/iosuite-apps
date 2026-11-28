import Charts
import SwiftUI

/// One account: what it holds, over time, what is coming (for a bank account), and its transactions.
struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    let account: MoneyAccount
    @State private var span = Span.quarter
    @State private var history: [DayValue] = []
    @State private var forecast: Forecast?
    @State private var recent: [Transaction] = []
    @State private var total = 0

    /// The account as the server has it now (after a refresh), else as it was when the row was tapped.
    private var a: MoneyAccount { model.accounts.first { $0.id == account.id } ?? account }
    private var listed: Bool { a.track == "transactions" }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(a.isAsset ? (listed ? "Balance" : "Value") : "Owed").font(.subheadline).foregroundStyle(.secondary)
                    Text(Money.text(a.balance, a.currency)).font(.largeTitle.bold()).monospacedDigit()
                    Text([a.kindLabel, a.detail, a.household ? "" : "Private"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary)
                    ValueChart(points: history.map { ($0.date, $0.value) }, currency: model.currency).frame(height: 150)
                    Picker("Period", selection: $span) {
                        ForEach(Span.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.vertical, 4)
                if let why = a.bank?.why, a.bank?.stale != nil {
                    Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                }
            }
            if let f = forecast, !f.events.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        if f.below, let low = f.low {
                            Label("Goes down to \(Money.text(low.value, f.currency)) on \(Day.label(low.day))", systemImage: "arrow.down.right.circle.fill")
                                .foregroundStyle(.red).font(.callout)
                        } else if let low = f.low {
                            Text("Lowest: \(Money.text(low.value, f.currency)) on \(Day.label(low.day))").font(.callout).foregroundStyle(.secondary)
                        }
                        ValueChart(points: f.points.map { ($0.date, $0.value) }, currency: f.currency, floor: f.floor).frame(height: 120)
                    }
                    .padding(.vertical, 4)
                    ForEach(f.events) { e in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.name)
                                Text(Day.label(e.day) + (e.late ? " · late" : "")).font(.footnote).foregroundStyle(e.late ? Color.orange : Color.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text((e.approximate ? "≈ " : "") + Money.text(e.amount, f.currency, sign: e.amount > 0)).monospacedDigit()
                                Text(Money.text(e.balance, f.currency)).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                } header: {
                    Text("The next \(f.days) days")
                } footer: {
                    Text("From the recurring transactions and the transfers made at a steady pace.")
                }
            }
            if listed {
                Section("Transactions") {
                    ForEach(recent) { t in
                        NavigationLink { TransactionView(transaction: t) { _ in Task { await load() } } } label: { TransactionRow(transaction: t, showAccount: false) }
                    }
                    if total > recent.count {
                        NavigationLink(value: API.Query(account: a.id)) { Text("All \(total) transactions") }
                    } else if recent.isEmpty {
                        Text("None yet.").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(a.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: span) { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            history = try await api.history(a.id, days: span.rawValue)
            if listed {
                if a.group == "cash" { forecast = try? await api.forecast(a.id) }
                let page = try await api.transactions(API.Query(account: a.id), limit: 15)
                recent = page.items
                total = page.total
            }
        } catch {
            model.failed(error, quiet: true)
        }
    }
}
