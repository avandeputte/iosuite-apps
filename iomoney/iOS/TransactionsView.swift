import SwiftUI

/// The Transactions tab: every transaction this person sees, searched and narrowed.
struct TransactionsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = API.Query()

    var body: some View {
        NavigationStack {
            TransactionList(query: query)
                .navigationTitle("Transactions")
                .searchable(text: $query.q, prompt: "Payee, category, notes, $280, 100-200")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { FilterMenu(query: $query) }
                }
                .navigationDestination(for: API.Query.self) { TransactionsScreen(query: $0) }
        }
    }
}

/// A list of transactions another screen leads to: an account's, a category's in a month, those that need a look.
struct TransactionsScreen: View {
    @EnvironmentObject private var model: AppModel
    let query: API.Query

    private var title: String {
        if query.review { return "Needs a look" }
        if let c = query.category { return c == "-" ? "No category" : c }
        if let a = query.account { return model.accounts.first { $0.id == a }?.name ?? "Transactions" }
        return "Transactions"
    }

    var body: some View {
        TransactionList(query: query)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// What narrows the list: an account, a category, a month, money out or in, those that need a look.
struct FilterMenu: View {
    @EnvironmentObject private var model: AppModel
    @Binding var query: API.Query

    private var months: [String] {
        let cal = Calendar(identifier: .gregorian)
        return (0..<24).compactMap { cal.date(byAdding: .month, value: -$0, to: Date()) }.map { String(Day.string($0).prefix(7)) }
    }

    var body: some View {
        Menu {
            Toggle(isOn: $query.review) { Label("Needs a look", systemImage: "eye") }
            Picker("Money", selection: $query.flow) {
                Text("Out and in").tag(String?.none)
                Text("Money out").tag(String?.some("out"))
                Text("Money in").tag(String?.some("in"))
            }
            Picker("Account", selection: $query.account) {
                Text("Every account").tag(Int?.none)
                ForEach(model.accounts.filter { $0.track == "transactions" }) { Text($0.name).tag(Int?.some($0.id)) }
            }
            .pickerStyle(.menu)
            Picker("Category", selection: $query.category) {
                Text("Every category").tag(String?.none)
                Text("No category").tag(String?.some("-"))
                ForEach(model.categories, id: \.category) { Text($0.category).tag(String?.some($0.category)) }
            }
            .pickerStyle(.menu)
            Picker("Month", selection: $query.month) {
                Text("Any time").tag(String?.none)
                ForEach(months, id: \.self) { Text(Day.month($0)).tag(String?.some($0)) }
            }
            .pickerStyle(.menu)
            if !query.isEmpty {
                Button("Show everything", role: .destructive) { query = API.Query() }
            }
        } label: {
            let narrowed = query != API.Query(q: query.q)
            Image(systemName: narrowed ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter")
    }
}

/// The transactions a query asks for, the newest first, a page at a time as the list is scrolled.
struct TransactionList: View {
    @EnvironmentObject private var model: AppModel
    let query: API.Query

    @State private var items: [Transaction] = []
    @State private var total = 0
    @State private var sum = 0.0
    @State private var loaded = false
    @State private var more = false
    @State private var failure: String?

    private var days: [(String, [Transaction])] {
        var out: [(String, [Transaction])] = []
        for t in items {
            if out.last?.0 == t.day { out[out.count - 1].1.append(t) } else { out.append((t.day, [t])) }
        }
        return out
    }

    var body: some View {
        List {
            if loaded, !query.isEmpty, !items.isEmpty {
                Section {
                    HStack {
                        Text("\(total) transaction\(total == 1 ? "" : "s")")
                        Spacer()
                        Amount(value: sum, currency: model.currency)
                    }
                    .font(.subheadline)
                    if query.review {
                        Button("Mark these \(items.count) as looked at") { markAll() }
                    }
                }
            }
            ForEach(days, id: \.0) { day, rows in
                Section(Day.label(day)) {
                    ForEach(rows) { t in
                        NavigationLink {
                            TransactionView(transaction: t, needsLook: query.review) { changed in replace(t.id, changed) }
                        } label: {
                            TransactionRow(transaction: t, showAccount: query.account == nil)
                        }
                        .swipeActions(edge: .leading) {
                            if query.review {
                                Button { mark([t.id]) } label: { Label("Looked at", systemImage: "checkmark") }.tint(.green)
                            }
                        }
                        .onAppear { if t.id == items.last?.id { Task { await loadMore() } } }
                    }
                }
            }
            if more { HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear) }
        }
        .overlay {
            if !loaded, failure == nil {
                ProgressView()
            } else if let failure, items.isEmpty {
                ContentUnavailableView("The transactions cannot be shown", systemImage: "wifi.slash", description: Text(failure))
            } else if loaded, items.isEmpty {
                ContentUnavailableView(query.review ? "Nothing needs a look" : "No transactions", systemImage: query.review ? "checkmark.circle" : "list.bullet",
                                       description: Text(query.isEmpty ? "" : "Nothing matches."))
            }
        }
        .refreshable { await load() }
        .task(id: query) {
            if !query.q.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }  // typing in the search waits a moment
            if !Task.isCancelled { await load() }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let page = try await api.transactions(query)
            guard !Task.isCancelled else { return }
            items = page.items
            total = page.total
            sum = page.sum
            failure = nil
            loaded = true
        } catch {
            if Task.isCancelled { return }
            if case APIError.signedOut = error { model.failed(error) }
            failure = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let api = model.api, !more, items.count < total else { return }
        more = true
        defer { more = false }
        if let page = try? await api.transactions(query, offset: items.count) {
            let have = Set(items.map(\.id))
            items += page.items.filter { !have.contains($0.id) }
            total = page.total
        }
    }

    /// A transaction changed on its own screen; nil: it left this list (looked at, on the Needs a look list).
    private func replace(_ id: Int, _ t: Transaction?) {
        if let t, let i = items.firstIndex(where: { $0.id == id }) {
            items[i] = t
        } else if t == nil {
            items.removeAll { $0.id == id }
            total = max(0, total - 1)
        }
    }

    private func mark(_ ids: [Int]) {
        guard let api = model.api else { return }
        Task {
            do {
                _ = try await api.review(ids)
                items.removeAll { ids.contains($0.id) }
                total = max(0, total - ids.count)
                await model.refresh()
                if items.isEmpty { await load() }
            } catch {
                model.failed(error)
            }
        }
    }

    private func markAll() { mark(items.map(\.id)) }
}

struct TransactionRow: View {
    let transaction: Transaction
    var showAccount = true

    var body: some View {
        let t = transaction
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).lineLimit(1)
                HStack(spacing: 4) {
                    if t.transfer != nil { Image(systemName: "arrow.left.arrow.right") }
                    Text(showAccount && t.account != nil ? "\(t.what) · \(t.account!)" : t.what).lineLimit(1)
                    if !(t.receipts ?? []).isEmpty { Image(systemName: "paperclip") }
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Amount(value: t.amount, currency: t.currency)
        }
        .opacity(t.hidden ? 0.5 : 1)
    }
}
