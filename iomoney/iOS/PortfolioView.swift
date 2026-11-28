import SwiftUI

/// What the investment accounts hold, at the latest quotes.
struct PortfolioView: View {
    @EnvironmentObject private var model: AppModel
    @State private var portfolio: Portfolio?
    @State private var byAccount = false

    var body: some View {
        NavigationStack {
            List {
                if let p = portfolio {
                    if p.items.isEmpty {
                        ContentUnavailableView("No holdings", systemImage: "chart.bar.xaxis", description: Text("What the investment accounts hold shows here."))
                    } else {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Investments").font(.subheadline).foregroundStyle(.secondary)
                                Text(Money.text(p.value, p.currency, cents: false)).font(.largeTitle.bold()).monospacedDigit()
                                if let d = p.dayChange {
                                    Text("\(Money.text(d, p.currency, sign: true)) (\(Money.percent(p.dayChangePct))) today")
                                        .font(.footnote).foregroundStyle(d >= 0 ? Color.green : Color.red)
                                }
                                if let g = p.gain {
                                    Text("\(Money.text(g, p.currency, cents: false, sign: true)) since bought").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            Picker("Show", selection: $byAccount) {
                                Text("By holding").tag(false)
                                Text("By account").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        if byAccount {
                            let names = p.items.reduce(into: [String]()) { out, h in
                                let n = h.account ?? "Account"
                                if !out.contains(n) { out.append(n) }
                            }
                            ForEach(names, id: \.self) { name in
                                let rows = p.items.filter { ($0.account ?? "Account") == name }
                                Section {
                                    ForEach(rows) { h in
                                        HoldingRow(symbol: h.symbol, name: h.name, shares: h.shares, price: h.price, currency: h.currency,
                                                   value: h.homeValue, changePct: h.dayChangePct, home: p.currency)
                                    }
                                } header: {
                                    HStack {
                                        Text(name)
                                        Spacer()
                                        Text(Money.text(rows.compactMap(\.homeValue).reduce(0, +), p.currency, cents: false))
                                    }
                                }
                            }
                        } else {
                            Section {
                                ForEach(p.bySymbol) { h in
                                    HoldingRow(symbol: h.symbol, name: h.name, shares: h.shares, price: h.price, currency: h.currency,
                                               value: h.homeValue, changePct: h.dayChangePct, home: p.currency)
                                }
                            }
                        }
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Investments")
            .refreshable { await load() }
            .task(id: model.locked) { await load() }
        }
    }

    private func load() async {
        guard let api = model.api, !model.locked else { return }
        do {
            portfolio = try await api.portfolio()
        } catch {
            model.failed(error, quiet: true)
        }
    }
}

struct HoldingRow: View {
    let symbol: String?
    let name: String?
    let shares: Double?
    let price: Double?
    let currency: String?
    let value: Double?
    let changePct: Double?
    let home: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(symbol ?? name ?? "Holding").font(.body.weight(.semibold))
                if symbol != nil, let name { Text(name).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                if let shares, let price {
                    Text("\(shares.formatted(.number.precision(.fractionLength(0...4)))) × \(Money.text(price, currency))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let value { Text(Money.text(value, home)).monospacedDigit() }
                if let changePct {
                    Text(Money.percent(changePct)).font(.footnote).monospacedDigit().foregroundStyle(changePct >= 0 ? Color.green : Color.red)
                }
            }
        }
    }
}
