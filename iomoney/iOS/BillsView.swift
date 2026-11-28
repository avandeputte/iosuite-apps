import SwiftUI

/// The recurring transactions on the days they fall: what is still to come, what is late, what was paid this month.
struct BillsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var bills: [Bill]?

    private var today: String { Day.string(Date()) }

    var body: some View {
        NavigationStack {
            List {
                if let bills {
                    let late = bills.filter { !$0.paid && $0.day < today }
                    let coming = bills.filter { !$0.paid && $0.day >= today }
                    let paid = bills.filter(\.paid).reversed()
                    if !late.isEmpty { Section("Not seen yet") { ForEach(late) { BillRow(bill: $0, late: true) } } }
                    if !coming.isEmpty {
                        Section {
                            ForEach(coming) { BillRow(bill: $0) }
                        } header: {
                            HStack {
                                Text("Coming up")
                                Spacer()
                                Text(Money.text(coming.map(\.amount).reduce(0, +), model.currency))
                            }
                        }
                    }
                    if !paid.isEmpty { Section("Paid this month") { ForEach(Array(paid)) { BillRow(bill: $0) } } }
                    if bills.isEmpty {
                        ContentUnavailableView("No bills", systemImage: "calendar", description: Text("Recurring transactions are found and added on the web."))
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Bills")
            .refreshable { await load() }
            .task(id: model.locked) { await load() }
        }
    }

    /// From the first of this month to six weeks from now.
    private func load() async {
        guard let api = model.api, !model.locked else { return }
        let cal = Calendar(identifier: .gregorian)
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        let end = cal.date(byAdding: .day, value: 42, to: Date()) ?? Date()
        do {
            bills = try await api.bills(start: start, end: end)
        } catch {
            model.failed(error, quiet: bills != nil)
            if bills == nil { bills = [] }
        }
    }
}

struct BillRow: View {
    let bill: Bill
    var late = false
    @State private var open = false

    private var hasProvider: Bool {
        guard let p = bill.provider else { return false }
        return ![p.accountNumber, p.phone, p.website, p.note].compactMap { $0 }.filter { !$0.isEmpty }.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: bill.paid ? "checkmark.circle.fill" : late ? "exclamationmark.circle" : "circle")
                    .foregroundStyle(bill.paid ? Color.green : late ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bill.merchant)
                    Text([Day.label(bill.day), bill.account].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text((bill.approximate ? "≈ " : "") + Money.text(bill.amount, bill.currency, sign: bill.amount > 0)).monospacedDigit()
                if hasProvider { Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
            .onTapGesture { if hasProvider { withAnimation { open.toggle() } } }
            if open, let p = bill.provider {
                VStack(alignment: .leading, spacing: 6) {
                    if let n = p.accountNumber, !n.isEmpty { Text("Account number \(n)").textSelection(.enabled) }
                    if let phone = p.phone, !phone.isEmpty {
                        if let url = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) { Link(phone, destination: url) } else { Text(phone) }
                    }
                    if let w = p.website, !w.isEmpty {
                        if let url = URL(string: w.contains("://") ? w : "https://" + w) { Link(w, destination: url) } else { Text(w) }
                    }
                    if let note = p.note, !note.isEmpty { Text(note).foregroundStyle(.secondary) }
                }
                .font(.footnote)
                .padding(.leading, 30)
            }
        }
    }
}
