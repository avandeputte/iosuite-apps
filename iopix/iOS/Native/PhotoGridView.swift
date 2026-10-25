import SwiftUI

/// One line of the grid: a day's heading, or a row of photos at their own shapes.
private struct GridRow: Identifiable {
    enum Kind { case day(String, Int, year: Int), photos([Int], CGFloat) }
    let id: Int
    let kind: Kind
}

/// Photos from the server as a grid, newest first by default, in rows by day as the web app shows them. Tap one to
/// see it full screen; Select picks several to favorite, add to an album or share.
struct PhotoGridScreen: View {
    let query: PhotoQuery
    var title: String?
    var isRoot = false
    var showUploads: () -> Void = {}

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var queue: UploadQueue
    @Environment(\.horizontalSizeClass) private var width
    @AppStorage("grid.size") private var size = "m"
    @State private var list: PhotoList?
    @State private var problem: String?
    @State private var sort: String?
    @State private var search = ""
    @State private var searchSent = ""
    @State private var kind = "all"  // all, photo, video (Photos tab only)
    @State private var selecting = false
    @State private var selected: Set<Int> = []
    @State private var viewer: PagerStart?
    @State private var newAlbum = false
    @State private var albumName = ""
    @State private var note: String?
    @State private var sharing: [URL] = []
    @State private var preparing = false

    private var wide: Bool { width == .regular }
    private var rowHeight: CGFloat {
        switch size {
        case "s": return wide ? 110 : 80
        case "l": return wide ? 250 : 170
        default: return wide ? 170 : 120
        }
    }

    private var currentSort: String { sort ?? query.value("sort") ?? "new" }

    /// What is asked of the server: the screen's filters, the order, and on the Photos tab the search and kind.
    private var effective: PhotoQuery {
        var q = query.setting("sort", currentSort)
        if isRoot {
            q = q.setting("q", searchSent.isEmpty ? nil : searchSent)
            q = q.setting("type", kind == "all" ? nil : kind)
        }
        return q
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    content(width: geo.size.width - (wide ? 32 : 8), proxy: proxy)
                }
                .refreshable { await load(force: true) }
                .toolbar { toolbar(proxy) }
            }
        }
        .navigationTitle(title ?? query.title(store))
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search people, tags, places, captions")
        .onSubmit(of: .search) { searchSent = search.trimmingCharacters(in: .whitespaces) }
        .onChange(of: search) { _, s in if s.isEmpty, !searchSent.isEmpty { searchSent = "" } }
        .task(id: effective) { await load() }
        .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
        .fullScreenCover(item: $viewer) { PhotoPager(start: $0).environmentObject(store).environmentObject(router) }
        .alert("New album", isPresented: $newAlbum) {
            TextField("Name", text: $albumName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await addToAlbum(nil, name: albumName) } }
        } message: { Text("The \(selected.count == 1 ? "photo goes" : "\(selected.count) photos go") into a new album.") }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) { Button("OK", role: .cancel) {} }
        .sheet(isPresented: Binding(get: { !sharing.isEmpty }, set: { if !$0 { cleanShared() } })) { ShareSheet(items: sharing) }
    }

    // MARK: the grid

    @ViewBuilder private func content(width: CGFloat, proxy: ScrollViewProxy) -> some View {
        if let list {
            let rows = Self.rows(list, width: max(width, 100), height: rowHeight, byDay: currentSort == "new" || currentSort == "old")
            LazyVStack(alignment: .leading, spacing: 3) {
                HStack {
                    let noun = list.videos.count == list.ids.count ? "video" : list.videos.isEmpty ? "photo" : "item"
                    Text(list.ids.count == 1 ? "1 \(noun)" : "\(list.ids.count.formatted()) \(noun)s").font(.subheadline).foregroundStyle(.secondary)
                    if isRoot, !query.filters.isEmpty { Spacer() }
                    chips
                }
                .padding(.vertical, 6)
                if list.ids.isEmpty {
                    Text(searchSent.isEmpty ? "No photos here." : "Nothing matches “\(searchSent)”.")
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
                Button("Try again") { Task { await load(force: true) } }.buttonStyle(.borderedProminent)
            }
            .padding(32).frame(maxWidth: .infinity).padding(.top, 60)
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
                .overlay(alignment: .bottomLeading) {
                    if list.isVideo(i) { Image(systemName: "play.fill").font(.caption2).foregroundStyle(.white).shadow(radius: 2).padding(5) }
                }
                .overlay(alignment: .topTrailing) {
                    if store.favoriteIDs.contains(id) { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.white).shadow(radius: 2).padding(5) }
                }
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

    /// The filters this list came with, as chips (tap one to drop it).
    @ViewBuilder private var chips: some View {
        if isRoot {
            Menu {
                Picker("Show", selection: $kind) {
                    Text("Photos and videos").tag("all"); Text("Photos").tag("photo"); Text("Videos").tag("video")
                }
            } label: {
                Label(kind == "all" ? "All" : kind == "photo" ? "Photos" : "Videos", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline)
            }
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder private func toolbar(_ proxy: ScrollViewProxy) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if selecting {
                Button("Done") { selecting = false; selected = [] }
            } else {
                Menu {
                    Picker("Order", selection: Binding(get: { currentSort }, set: { sort = $0 })) {
                        Text("Newest first").tag("new"); Text("Oldest first").tag("old")
                        Text("Recently changed").tag("added"); Text("Top rated").tag("rating")
                        Text("File name").tag("name"); Text("Largest files").tag("size")
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

    private var selectionBar: some View {
        HStack(spacing: 22) {
            Text(selected.isEmpty ? "Select photos" : "\(selected.count) selected").font(.subheadline.weight(.medium))
            Spacer()
            Button { Task { await favorite(true) } } label: { Image(systemName: "heart") }.accessibilityLabel("Add to favorites")
            Button { Task { await favorite(false) } } label: { Image(systemName: "heart.slash") }.accessibilityLabel("Remove from favorites")
            Menu {
                ForEach(store.albums) { a in Button(a.name) { Task { await addToAlbum(a.id) } } }
                Divider()
                Button { albumName = ""; newAlbum = true } label: { Label("New album…", systemImage: "plus") }
            } label: { Image(systemName: "rectangle.stack.badge.plus") }
                .accessibilityLabel("Add to album")
            Button { Task { await share() } } label: {
                if preparing { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
            }
            .accessibilityLabel("Share")
        }
        .font(.title3)
        .disabled(selected.isEmpty || preparing)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }

    private func favorite(_ on: Bool) async {
        if await store.setFavorites(Array(selected), on) { selecting = false; selected = [] }
        else { note = "Couldn't change your favorites. Check that you're signed in." }
    }

    private func addToAlbum(_ album: Int?, name: String? = nil) async {
        do {
            _ = try await store.addToAlbum(Array(selected), album: album, name: name)
            note = "Added \(selected.count == 1 ? "1 photo" : "\(selected.count) photos") to \(album.flatMap { a in store.albums.first { $0.id == a }?.name } ?? name ?? "the album")."
            selecting = false; selected = []
        } catch {
            note = error.localizedDescription
        }
    }

    /// The originals, downloaded for the share sheet (at most 50 at a time).
    private func share() async {
        preparing = true
        defer { preparing = false }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for id in selected.prefix(50) {
            guard let (tmp, resp) = try? await IopixClient.shared.session.download(for: IopixClient.shared.request("orig/\(id)")),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let name = (resp as? HTTPURLResponse).flatMap { PhotoPager.filename($0) } ?? "iopix-\(id).jpg"
            var dst = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dst.path) { dst = dir.appendingPathComponent("\(id)-\(name)") }
            if (try? FileManager.default.moveItem(at: tmp, to: dst)) != nil { out.append(dst) }
        }
        if out.isEmpty { note = "Couldn't get the photos to share." } else { sharing = out }
    }

    private func cleanShared() {
        if let first = sharing.first { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        sharing = []
    }

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
            out.append(GridRow(id: out.count, kind: .photos(pending, h)))
            pending = []; sum = 0
        }
        var lastDay: DateComponents?
        var dayStart = 0
        for i in list.ids.indices {
            if byDay {
                let t = i < list.times.count ? list.times[i] : 0
                let d = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
                if d != lastDay {
                    flush(full: false)
                    if let headerIndex = out.lastIndex(where: { if case .day = $0.kind { return true } else { return false } }),
                       case .day(let label, _, let y) = out[headerIndex].kind {
                        out[headerIndex] = GridRow(id: out[headerIndex].id, kind: .day(label, i - dayStart, year: y))
                    }
                    let label = t > 0 ? dayFormat.string(from: Date(timeIntervalSince1970: t)) : "Date unknown"
                    out.append(GridRow(id: out.count, kind: .day(label, 0, year: d.year ?? 0)))
                    lastDay = d
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
