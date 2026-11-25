import SwiftUI

/// The articles one list shows, shared with the article open from it (which marks, stars and steps through them).
@MainActor
final class ArticleList: ObservableObject {
    @Published var items: [Article] = []
    @Published var next: String?
    @Published var loaded = false
    @Published var loading = false
    @Published var problem: String?
    private var asked = 0

    /// The list from its top (`more`: the articles after the ones shown).
    func load(_ account: Account?, scope: NewsScope, show: NewsShow, search: String, more: Bool = false) async {
        guard let account else { return }
        if more && (next == nil || loading) { return }
        asked += 1
        let mine = asked
        loading = true
        defer { if mine == asked { loading = false } }
        do {
            let page = try await API(account: account).articles(scope, show: show, search: search, before: more ? next : nil)
            guard mine == asked else { return }  // a newer question was asked meanwhile (another filter, more typed)
            if more {
                let have = Set(items.map(\.id))
                items += page.items.filter { !have.contains($0.id) }
            } else {
                items = page.items
            }
            next = page.next
            loaded = true
            problem = nil
        } catch {
            guard mine == asked else { return }
            problem = NewsModel.told(error)
        }
    }

    /// Read or not, at once; back when the start page says no.
    func mark(_ article: Article, read: Bool, account: Account?, news: NewsModel) async {
        guard let account, let i = items.firstIndex(where: { $0.id == article.id }), items[i].read != read else { return }
        items[i].read = read
        news.count(article, read: read)
        do {
            try await API(account: account).mark([article.id], read: read)
        } catch {
            if let j = items.firstIndex(where: { $0.id == article.id }) { items[j].read = !read }
            news.count(article, read: !read)
            problem = NewsModel.told(error)
        }
    }

    func star(_ article: Article, _ on: Bool, account: Account?, news: NewsModel) async {
        guard let account, let i = items.firstIndex(where: { $0.id == article.id }), items[i].starred != on else { return }
        items[i].starred = on
        news.overview.starred = max(0, news.overview.starred + (on ? 1 : -1))
        do {
            try await API(account: account).mark([article.id], starred: on)
        } catch {
            if let j = items.firstIndex(where: { $0.id == article.id }) { items[j].starred = !on }
            news.overview.starred = max(0, news.overview.starred + (on ? -1 : 1))
            problem = NewsModel.told(error)
        }
    }
}

/// The articles of all feeds, a folder, a feed, or the starred ones: the newest first.
struct ArticleListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var news: NewsModel
    let scope: NewsScope

    @StateObject private var list = ArticleList()
    @AppStorage("newsShow") private var showRaw = NewsShow.unread.rawValue
    @State private var query = ""
    @State private var reading: Int?
    @State private var asking = false

    private var show: NewsShow { scope == .starred ? .starred : (NewsShow(rawValue: showRaw) ?? .unread) }
    private var search: String { query.trimmingCharacters(in: .whitespaces) }

    private var title: String {
        switch scope {
        case .all: return "All feeds"
        case .starred: return "Starred"
        case .folder(let name): return name
        case .feed(let id): return news.overview.feeds.first { $0.id == id }?.title ?? "Feed"
        }
    }

    var body: some View {
        List {
            if let problem = list.problem, list.loaded {
                Label(problem, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(list.items) { article in
                Button { reading = article.id } label: { ArticleRow(article: article, showFeed: !isOneFeed) }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        Button { Task { await list.mark(article, read: !article.read, account: model.account, news: news) } } label: {
                            Label(article.read ? "Unread" : "Read", systemImage: article.read ? "circle.fill" : "checkmark.circle")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button { Task { await list.star(article, !article.starred, account: model.account, news: news) } } label: {
                            Label(article.starred ? "Unstar" : "Star", systemImage: article.starred ? "star.slash" : "star")
                        }
                        .tint(.yellow)
                    }
                    .onAppear {
                        if article.id == list.items.last?.id { Task { await load(more: true) } }
                    }
            }
            if list.loading && list.loaded && list.next != nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay { emptyState }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search titles and text")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .refreshable {
            await news.refresh(model.account, look: true)
            await load()
        }
        .toolbar {
            if scope != .starred {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Show", selection: $showRaw) {
                        ForEach([NewsShow.unread, .all]) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { asking = true } label: { Image(systemName: "checkmark.circle") }
                        .accessibilityLabel("Mark all as read")
                        .disabled(!list.items.contains { !$0.read })
                }
            }
        }
        .confirmationDialog("Mark everything in \(title) as read?", isPresented: $asking, titleVisibility: .visible) {
            Button("Mark all as read") { Task { await markAll() } }
        }
        .navigationDestination(item: $reading) { ArticleView(list: list, id: $0) }
        .task(id: Asked(show: show, search: search)) {
            if !search.isEmpty { try? await Task.sleep(nanoseconds: 350_000_000) }  // while typing: once it pauses
            if Task.isCancelled { return }
            await load()
        }
    }

    private struct Asked: Hashable { var show: NewsShow; var search: String }

    private var isOneFeed: Bool {
        if case .feed = scope { return true }
        return false
    }

    private func load(more: Bool = false) async {
        await list.load(model.account, scope: scope, show: show, search: search, more: more)
    }

    private func markAll() async {
        guard let account = model.account else { return }
        do {
            try await API(account: account).markAllRead(scope, upto: list.items.map(\.id).max())
        } catch {
            model.problem = NewsModel.told(error)
        }
        await news.refresh(account)
        await load()
    }

    @ViewBuilder private var emptyState: some View {
        if !list.loaded {
            if let problem = list.problem {
                ContentUnavailableView {
                    Label("The articles are not available", systemImage: "newspaper")
                } description: {
                    Text(problem)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        } else if list.items.isEmpty {
            if !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if show == .unread {
                ContentUnavailableView("Nothing new", systemImage: "checkmark.circle", description: Text("You have read it all."))
            } else if show == .starred {
                ContentUnavailableView("No starred articles", systemImage: "star", description: Text("Star an article to keep it here."))
            } else {
                ContentUnavailableView("No articles", systemImage: "newspaper")
            }
        }
    }
}

private struct ArticleRow: View {
    let article: Article
    let showFeed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(article.read ? Color.clear : Color.accentColor).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(article.title)
                    .font(.headline)
                    .fontWeight(article.read ? .regular : .semibold)
                    .foregroundStyle(article.read ? .secondary : .primary)
                    .lineLimit(3)
                if let text = article.text, !text.isEmpty {
                    Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 5) {
                    if article.starred { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    if article.audio != nil { Image(systemName: "headphones") }
                    Text([showFeed ? article.feed : nil, article.ago].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let image = article.image.flatMap({ URL(string: $0) }) {
                AsyncImage(url: image) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { Color(.tertiarySystemFill) }
                }
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(article.read ? 0.6 : 1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
