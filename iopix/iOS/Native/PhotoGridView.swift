import SwiftUI

/// One line of the grid: a day's heading, or a row of photos at their own shapes.
private struct GridRow: Identifiable {
    enum Kind { case day(String, Int, year: Int), photos([Int], CGFloat) }
    let id: String  // from the photos in it, so a new list replaces every row instead of reusing stale ones
    let kind: Kind
}

/// Photos from the server as a grid, newest first by default, in rows by day as the web app shows them. Tap one to
/// see it full screen; Select picks several to favorite, add to an album or share.
struct PhotoGridScreen: View {
    let query: PhotoQuery
    var title: String?
    var isRoot = false
    var showUploads: () -> Void = {}

    @EnvironmentObject fileprivate var store: LibraryStore
    @EnvironmentObject fileprivate var router: Router
    @EnvironmentObject private var queue: UploadQueue
    @Environment(\.horizontalSizeClass) private var width
    @AppStorage("grid.size") private var size = "m"
    @State private var list: PhotoList?
    @State private var problem: String?
    @State private var sort: String?
    @State private var search = ""
    @State fileprivate var filters: PhotoQuery
    @State fileprivate var showFilters = false
    @State fileprivate var download = false
    @State private var signingIn = false
    @State private var signInNeeded = false
    @State fileprivate var selecting = false
    @State private var selected: Set<Int> = []
    @State fileprivate var viewer: PagerStart?

    init(query: PhotoQuery, title: String? = nil, isRoot: Bool = false, showUploads: @escaping () -> Void = {}) {
        self.query = query
        self.title = title
        self.isRoot = isRoot
        self.showUploads = showUploads
        _filters = State(initialValue: query)
    }

    private var wide: Bool { width == .regular }
    private var rowHeight: CGFloat {
        switch size {
        case "s": return wide ? 110 : 80
        case "l": return wide ? 250 : 170
        default: return wide ? 170 : 120
        }
    }

    /// A search by meaning (sem, like, concept): the server's order is best match first unless a sort is asked for.
    private var rankable: Bool { ["sem", "like", "concept"].contains { filters.value($0) != nil } }
    private var currentSort: String { sort ?? filters.value("sort") ?? (rankable || list?.ranked == true ? "rel" : "new") }

    /// What is asked of the server: the filters chosen here (on top of the ones the screen opened with), in order.
    /// "Best match" is the server's own order for a ranked search, so no sort= goes with it.
    fileprivate var effective: PhotoQuery { filters.setting("sort", currentSort == "rel" ? nil : currentSort) }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    content(width: geo.size.width - (wide ? 32 : 8), proxy: proxy)
                }
                .refreshable { await load(force: true) }
                .hardTopEdge()
                .toolbar { toolbar(proxy) }
            }
        }
        .navigationTitle(title ?? filters.title(store))
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .librarySearch(text: $search, query: $filters) {
            // the text becomes a chip (as the web app does); its cross takes it away again
            let q = search.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty, !filters.has("q", q) { filters = filters.adding("q", q) }
            search = ""
        }
        .task(id: effective) { await load() }
        .task { await BulkCatalog.shared.load() }
        .onReceive(NotificationCenter.default.publisher(for: .iopixPhotosChanged)) { n in
            if let gone = n.userInfo?["removed"] as? [Int], !gone.isEmpty { list?.ids.removeAll { gone.contains($0) } }
            Task { await load() }
        }
        .modifier(Sheets(screen: self))
    }

    /// The sheets and bars of the screen (apart from the main chain, which the compiler otherwise chokes on).
    private struct Sheets: ViewModifier {
        let screen: PhotoGridScreen

        func body(content: Content) -> some View {
            content
                .overlay(alignment: .bottom) { BulkToastOverlay() }
                .sheet(isPresented: screen.$showFilters) { FilterSheet(query: screen.$filters) }
                .sheet(isPresented: screen.$download) { BulkDownloadSheet(query: screen.effective, title: screen.title ?? screen.filters.title(screen.store)) }
                .safeAreaInset(edge: .bottom) { if screen.selecting { screen.bulkBar } }
                .fullScreenCover(item: screen.$viewer) { PhotoPager(start: $0).environmentObject(screen.store).environmentObject(screen.router) }
        }
    }

    private var bulkBar: some View {
        // the selection in the grid's order (what Copy metadata offers first, how a share or zip is numbered)
        let ids = list.map { l in l.ids.filter { selected.contains($0) } } ?? Array(selected)
        return BulkActionBar(ids: ids, total: list?.ids.count ?? 0, album: filters.value("ualbum").flatMap(Int.init),
                             selectAll: { selected = Set(list?.ids ?? []) }, deselect: { selected = [] }) { outcome in
            // the selection stays after a metadata change (the sheet may still be open, saving one change at a
            // time); it ends when the photos left the list
            if case .removed(let gone) = outcome {
                selecting = false; selected = []
                list?.ids.removeAll { gone.contains($0) }
            }
            Task { await load() }
        }
    }

    // MARK: the grid

    @ViewBuilder private func content(width: CGFloat, proxy: ScrollViewProxy) -> some View {
        if let list {
            let rows = Self.rows(list, width: max(width, 100), height: rowHeight, byDay: currentSort == "new" || currentSort == "old")
            LazyVStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top) {
                    let noun = list.videos.count == list.ids.count ? "video" : list.videos.isEmpty ? "photo" : "item"
                    Text(list.ids.count == 1 ? "1 \(noun)" : "\(list.ids.count.formatted()) \(noun)s").font(.subheadline).foregroundStyle(.secondary)
                        .padding(.top, 6)
                    FilterChips(query: $filters)
                }
                .padding(.vertical, 6)
                if list.ids.isEmpty {
                    Text(filters.value("q").map { "Nothing matches “\($0)”." } ?? "No photos here.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 80)
                }
                ForEach(rows) { row in
                    switch row.kind {
                    case .day(let label, let n, _):
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(Hue.indigo).frame(width: 4, height: 18)
                            Text(label).font(.headline)
                            Text("\(n)").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.top, 14).padding(.bottom, 4)
                        .id(row.id)
                    case .photos(let indices, let h):
                        HStack(spacing: 3) {
                            ForEach(indices, id: \.self) { i in tile(list, i, h) }
                        }
                        .id(row.id)
                    }
                }
            }
            .padding(.horizontal, wide ? 16 : 4)
            .padding(.bottom, 30)
        } else if let problem {
            VStack(spacing: 12) {
                Text("Couldn't load the photos").font(.headline)
                Text(problem).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if signInNeeded {
                    Button("Sign in") { signingIn = true }.buttonStyle(.borderedProminent)
                } else {
                    Button("Try again") { Task { await load(force: true) } }.buttonStyle(.borderedProminent)
                }
            }
            .padding(32).frame(maxWidth: .infinity).padding(.top, 60)
            .sheet(isPresented: $signingIn, onDismiss: { Task { await load(force: true) } }) { SignInView(changeServer: showUploads) }
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
        }
    }

    private func tile(_ list: PhotoList, _ i: Int, _ h: CGFloat) -> some View {
        let id = list.ids[i]
        let on = selected.contains(id)
        return Button {
            if selecting { if on { selected.remove(id) } else { selected.insert(id) } }
            else { viewer = PagerStart(list: list, index: i) }
        } label: {
            RemoteImage(path: "thumb/\(id)")
                .frame(width: CGFloat(list.ratio(i)) * h, height: h)
                .clipped()
                .overlay { TileBadges(list: list, index: i, favorite: store.favoriteIDs.contains(id)) }
                .overlay {
                    if selecting {
                        ZStack(alignment: .bottomTrailing) {
                            Color.black.opacity(on ? 0.25 : 0)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(on ? Color.accentColor : .white).background(on ? Circle().fill(.white) : nil)
                                .shadow(radius: 2).padding(6)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .contextMenu {
            let fav = store.favoriteIDs.contains(id)
            Button { Task { await store.setFavorite(id, !fav) } } label: {
                Label(fav ? "Remove from Favorites" : "Add to Favorites", systemImage: fav ? "heart.slash" : "heart")
            }
            Button { router.open("#/photos?p=\(id)") } label: { Label("Open in iopix", systemImage: "safari") }
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder private func toolbar(_ proxy: ScrollViewProxy) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if selecting {
                Button("Done") { selecting = false; selected = [] }
            } else {
                Button { showFilters = true } label: {
                    Image(systemName: filters.filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Filters")
                // its own item, not inside the menu below: its alerts and sheet need a view that stays on screen
                SavedSearchesMenu(query: $filters)
                Menu {
                    Picker("Order", selection: Binding(get: { currentSort }, set: { sort = $0 })) {
                        if list?.ranked == true { Text("Best match").tag("rel") }
                        Text("Newest first").tag("new"); Text("Oldest first").tag("old")
                        Text("Recently changed").tag("added"); Text("Top rated").tag("rating")
                        Text("Sharpest first").tag("sharp"); Text("Blurriest first").tag("blur")
                        Text("File name").tag("name"); Text("Largest files").tag("size")
                    }
                    if list?.ids.isEmpty == false, !filters.filters.isEmpty {  // the whole library is not offered as one download
                        Button { download = true } label: { Label("Download all as zip", systemImage: "arrow.down.circle") }
                    }
                    Picker("Size", selection: $size) {
                        Text("Small").tag("s"); Text("Medium").tag("m"); Text("Large").tag("l")
                    }
                    if let list, currentSort == "new" || currentSort == "old" {
                        let years = Self.years(list)
                        if years.count > 1 {
                            Menu("Jump to year") {
                                ForEach(years, id: \.self) { y in
                                    Button(String(y)) { jump(to: y, proxy: proxy) }
                                }
                            }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                Button("Select") { selecting = true }
                if isRoot {
                    Button(action: showUploads) { Image(systemName: queue.pending.isEmpty ? "square.and.arrow.up" : "arrow.up.circle") }
                        .accessibilityLabel("Send photos to iopix")
                }
            }
        }
    }

    private func jump(to year: Int, proxy: ScrollViewProxy) {
        guard let list else { return }
        let rows = Self.rows(list, width: 390, height: rowHeight, byDay: true)
        if let r = rows.first(where: { if case .day(_, _, let y) = $0.kind { return y == year } else { return false } }) {
            withAnimation { proxy.scrollTo(r.id, anchor: .top) }
        }
    }

    // MARK: selection

    // MARK: data

    private func load(force: Bool = false) async {
        if force { list = nil }
        problem = nil
        do {
            let l = try await PhotoList.load(effective.items)
            list = l
            selected = selected.intersection(l.ids)
        } catch {
            if list == nil { problem = error.localizedDescription }
            if case IopixError.needsSignIn = error { signInNeeded = true } else { signInNeeded = false }
        }
    }

    /// Photo times are the camera's clock stored as if it were UTC, as the web app shows them.
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("EEE MMM d yyyy")
        return f
    }()

    private static func years(_ list: PhotoList) -> [Int] {
        var seen: [Int] = []
        for t in list.times where t > 0 {
            let y = calendar.component(.year, from: Date(timeIntervalSince1970: t))
            if seen.last != y, !seen.contains(y) { seen.append(y) }
        }
        return seen
    }

    /// The grid's lines for a width: a heading at each new day (when sorted by date), then rows that fill the width.
    private static func rows(_ list: PhotoList, width: CGFloat, height: CGFloat, byDay: Bool) -> [GridRow] {
        var out: [GridRow] = []
        var pending: [Int] = []
        var sum = 0.0
        let spacing: CGFloat = 3
        func flush(full: Bool) {
            guard !pending.isEmpty else { return }
            let gaps = spacing * CGFloat(pending.count - 1)
            let h = full ? (width - gaps) / CGFloat(sum) : min(height, (width - gaps) / CGFloat(sum))
            out.append(GridRow(id: "p\(list.ids[pending[0]])", kind: .photos(pending, h)))
            pending = []; sum = 0
        }
        var lastDay: String?
        var dayStart = 0
        for i in list.ids.indices {
            if byDay {
                let t = i < list.times.count ? list.times[i] : 0
                let d = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
                // an approximate date has its own heading ("May 1992", "1992", "Date unknown"), not its placeholder day
                let p = list.precision[i]
                let key = p.map { "p\($0)|\(PhotoDates.text(t, precision: $0))" } ?? "\(d.year ?? 0)-\(d.month ?? 0)-\(d.day ?? 0)"
                if key != lastDay {
                    flush(full: false)
                    if let headerIndex = out.lastIndex(where: { if case .day = $0.kind { return true } else { return false } }),
                       case .day(let label, _, let y) = out[headerIndex].kind {
                        out[headerIndex] = GridRow(id: out[headerIndex].id, kind: .day(label, i - dayStart, year: y))
                    }
                    let label = p != nil ? PhotoDates.text(t, precision: p) : t > 0 ? dayFormat.string(from: Date(timeIntervalSince1970: t)) : "Date unknown"
                    out.append(GridRow(id: "d\(list.ids[i])", kind: .day(label, 0, year: d.year ?? 0)))
                    lastDay = key
                    dayStart = i
                }
            }
            pending.append(i)
            sum += list.ratio(i)
            if CGFloat(sum) * height + spacing * CGFloat(pending.count - 1) >= width { flush(full: true) }
        }
        flush(full: false)
        if let headerIndex = out.lastIndex(where: { if case .day = $0.kind { return true } else { return false } }),
           case .day(let label, _, let y) = out[headerIndex].kind {
            out[headerIndex] = GridRow(id: out[headerIndex].id, kind: .day(label, list.ids.count - dayStart, year: y))
        }
        return out
    }
}

extension PhotoQuery {
    /// A heading for the list, from its filters (the person's or tag's name, the year, the place...).
    @MainActor func title(_ store: LibraryStore) -> String {
        func int(_ k: String) -> Int? { value(k).flatMap(Int.init) }
        if let t = int("tag") {
            return store.people.first { $0.id == t }?.name ?? store.tags.first { $0.id == t }?.name
                ?? store.summary.things.first { $0.id == t }?.name ?? "Tag"
        }
        if let a = int("ualbum") { return store.albums.first { $0.id == a }?.name ?? "Album" }
        if let a = int("album") { return store.folders.first { $0.id == a }?.name ?? "Folder" }
        if value("fav") == "1" { return "Favorites" }
        if let y = value("year") { return y }
        if let p = value("place") { return p }
        if value("md") != nil { return "On this day" }
        if let f = value("from"), let t = value("to") { return f == t ? f : "\(f) – \(t)" }
        if let c = value("camera") { return c }
        if let c = value("creator") { return c }
        if let c = value("fmt") { return c }
        if let c = value("concept") { return c.prefix(1).uppercased() + c.dropFirst() }
        if let r = value("rating") { return r == "5" ? "★★★★★" : "★★★ and up" }
        if value("type") == "video" { return "Videos" }
        if value("untagged") != nil { return "Untagged" }
        if value("geo") == "0" { return "No location" }
        if value("hastext") != nil { return "Contains text" }
        if value("blurry") != nil { return "Blurry" }
        if value("bbox") != nil { return "This area" }
        if let q = value("q") { return "“\(q)”" }
        return "Photos"
    }
}
