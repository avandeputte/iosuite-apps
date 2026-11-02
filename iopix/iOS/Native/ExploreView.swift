import SwiftUI

/// The web app's colours for Explore's sections.
enum Hue {
    static let purple = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let blue = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let amber = Color(red: 0.96, green: 0.62, blue: 0.04)
    static let teal = Color(red: 0.08, green: 0.72, blue: 0.65)
    static let green = Color(red: 0.13, green: 0.77, blue: 0.37)
    static let slate = Color(red: 0.39, green: 0.45, blue: 0.55)
    static let rose = Color(red: 0.96, green: 0.25, blue: 0.37)
    static let indigo = Color(red: 0.39, green: 0.40, blue: 0.95)
    static let orange = Color(red: 0.98, green: 0.45, blue: 0.09)
    static let cyan = Color(red: 0.02, green: 0.71, blue: 0.83)
}

struct ThenNowPair: Identifiable {
    struct Face { let photo: Int; let ts: Double; let rect: [Int] }
    let tag: Int, name: String, then: Face, now: Face, years: Double
    var id: Int { tag }
}

struct Trip: Identifiable {
    let title: String, when: String, from: String, to: String, count: Int, days: Int, cover: Int?
    var id: String { from + to + title }
}

struct Concept: Identifiable {
    let name: String, count: Int, cover: Int?
    var id: String { name }
}

/// What Explore shows beyond the library summary: today's photos, a random handful, then-and-now pairs, trips,
/// detected content and who you are.
@MainActor
final class ExploreModel: ObservableObject {
    @Published var today = PhotoList()
    @Published var random = PhotoList()
    @Published var pairs: [ThenNowPair] = []
    @Published var trips: [Trip] = []
    @Published var concepts: [Concept] = []
    @Published var account: Account?
    /// From the server's status: editing is on, there is no digiKam database ("None" in Settings), and how many
    /// edits made here are not in digiKam's database yet (the web app's S.EDITING, S.NO_DK and S.PENDING).
    @Published var editing = false
    @Published var noDigikam = false
    @Published var pending = 0

    static var monthDay: String {
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        return String(format: "%02d-%02d", c.month ?? 1, c.day ?? 1)
    }

    func load() async {
        // iopix 1.78 and later bring most of the page in one request; older servers answer each part on its own
        if let j = try? await IopixClient.shared.json("api/explore", query: [URLQueryItem(name: "md", value: Self.monthDay),
                                                                            URLQueryItem(name: "n", value: "36"),
                                                                            URLQueryItem(name: "pairs", value: "3")]) {
            if let d = j["onThisDay"] as? [String: Any] { today = PhotoList(json: d) } else { today = PhotoList() }
            if let d = j["random"] as? [String: Any] { random = d["geo"] != nil ? PhotoList(json: d) : await Self.withMarks(PhotoList(json: d)) }
            if let d = j["thenAndNow"] as? [String: Any] { pairs = Self.pairs(d) }
            if let list = j["events"] as? [[String: Any]] { trips = Self.trips(["events": list]) }
            else if let d = j["events"] as? [String: Any] { trips = Self.trips(d) }
            async let c: Void = loadConcepts()
            async let s: Void = loadStatus()
            async let a = try? IopixClient.shared.account()
            _ = await (c, s)
            account = await a
            return
        }
        async let t: Void = loadToday()
        async let r: Void = shuffle()
        async let p: Void = loadPairs()
        async let e: Void = loadTrips()
        async let c: Void = loadConcepts()
        async let s: Void = loadStatus()
        async let a = try? IopixClient.shared.account()
        _ = await (t, r, p, e, c, s)
        account = await a
    }

    func loadStatus() async {
        guard let j = try? await IopixClient.shared.json("api/status") else { return }
        editing = j["editing"] as? Bool ?? false
        noDigikam = (j["digikam"] as? [String: Any])?["none"] as? Bool ?? false
        pending = (j["pendingEdits"] as? NSNumber)?.intValue ?? 0
    }

    func loadToday() async {
        today = (try? await PhotoList.load([URLQueryItem(name: "md", value: Self.monthDay)])) ?? PhotoList()
    }

    func shuffle() async {
        if let j = try? await IopixClient.shared.json("api/random", query: [URLQueryItem(name: "n", value: "36")]) { random = j["geo"] != nil ? PhotoList(json: j) : await Self.withMarks(PhotoList(json: j)) }
    }

    /// Before iopix 1.78.2 the random list comes without the faces, location and video marks: they are read for the same ids from the
    /// photo list (which keeps its own order) and put back in the random order.
    static func withMarks(_ list: PhotoList) async -> PhotoList {
        guard !list.ids.isEmpty, list.geo.isEmpty, list.faces.isEmpty, list.videos.isEmpty,
              let full = try? await PhotoList.load([URLQueryItem(name: "ids", value: list.ids.map(String.init).joined(separator: ","))]) else { return list }
        var at: [Int: Int] = [:]
        for (i, id) in full.ids.enumerated() { at[id] = i }
        var out = list
        for (i, id) in list.ids.enumerated() {
            guard let j = at[id] else { continue }
            if full.geo.contains(j) { out.geo.insert(i) }
            if full.faces.contains(j) { out.faces.insert(i) }
            if full.videos.contains(j) { out.videos.insert(i) }
            if let d = full.durations[j] { out.durations[i] = d }
        }
        return out
    }

    func loadPairs() async {
        guard let j = try? await IopixClient.shared.json("api/thenandnow", query: [URLQueryItem(name: "n", value: "3")]) else { return }
        pairs = Self.pairs(j)
    }

    static func pairs(_ j: [String: Any]) -> [ThenNowPair] {
        func face(_ d: Any?) -> ThenNowPair.Face? {
            guard let d = d as? [String: Any], let p = (d["photo"] as? NSNumber)?.intValue else { return nil }
            return .init(photo: p, ts: (d["ts"] as? NSNumber)?.doubleValue ?? 0, rect: (d["rect"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue })
        }
        return (j["pairs"] as? [[String: Any]] ?? []).compactMap { p in
            guard let tag = (p["tag"] as? NSNumber)?.intValue, let a = face(p["then"]), let b = face(p["now"]) else { return nil }
            return ThenNowPair(tag: tag, name: p["name"] as? String ?? "", then: a, now: b, years: (p["years"] as? NSNumber)?.doubleValue ?? 0)
        }
    }

    func loadTrips() async {
        guard let j = try? await IopixClient.shared.json("api/events") else { return }
        trips = Self.trips(j)
    }

    static func trips(_ j: [String: Any]) -> [Trip] {
        (j["events"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "trip" }.prefix(8).compactMap { e in
            guard let from = e["from"] as? String, let to = e["to"] as? String else { return nil }
            return Trip(title: e["title"] as? String ?? from, when: e["when"] as? String ?? from, from: from, to: to,
                        count: (e["n"] as? NSNumber)?.intValue ?? 0, days: (e["days"] as? NSNumber)?.intValue ?? 1,
                        cover: (e["cover"] as? NSNumber)?.intValue)
        }
    }

    func loadConcepts() async {
        guard let j = try? await IopixClient.shared.json("api/concepts"), j["enabled"] as? Bool != false else { concepts = []; return }
        concepts = (j["concepts"] as? [[String: Any]] ?? []).compactMap { c in
            guard let name = c["name"] as? String else { return nil }
            return Concept(name: name, count: (c["n"] as? NSNumber)?.intValue ?? 0, cover: (c["cover"] as? NSNumber)?.intValue)
        }.sorted { $0.count > $1.count }.prefix(12).map { $0 }
    }
}

/// The library at a glance, as the web app's Explore page: the numbers, On this day, Rediscover, Then and now,
/// places, people, trips, detected content, tags, quick filters, years, cameras, photographers and file types.
struct ExploreView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var queue: UploadQueue
    @Environment(\.horizontalSizeClass) private var width
    @StateObject private var model = ExploreModel()
    @AppStorage("explore.size") private var size = "m"
    @State private var viewer: PagerStart?
    @State private var signingIn = false
    var showUploads: () -> Void = {}

    private var wide: Bool { width == .regular }
    private var rowHeight: CGFloat {
        switch size {
        case "s": return wide ? 100 : 72
        case "l": return wide ? 220 : 160
        default: return wide ? 150 : 110
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.needsSignIn {
                    signIn
                } else if let problem = store.problem, !store.loaded {
                    unreachable(problem)
                } else if !store.loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
                } else {
                    content
                }
            }
            .background(alignment: .top) { wash }
            .hardTopEdge()
            .navigationTitle("Explore")
            .globalSearch()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { sizePicker }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: showUploads) {
                        Image(systemName: !queue.pending.isEmpty ? "arrow.up.circle" : !queue.reviewing.isEmpty ? "photo.badge.plus" : "square.and.arrow.up")
                    }
                    .accessibilityLabel("Send photos to iopix")
                }
            }
            .refreshable { await reload() }
            .task { if !store.loaded { await reload() } else if model.account == nil { await model.load() } }
            .onChange(of: queue.account) { _, a in
                guard let a else { return }  // unknown (offline): nothing to redo
                // signed in: a library not shown yet; signed out: a library that is no longer this account's
                if a.signedIn ? (store.needsSignIn || !store.loaded) : (store.loaded && !store.needsSignIn) { Task { await reload() } }
            }
            .fullScreenCover(item: $viewer) { PhotoPager(start: $0).environmentObject(store).environmentObject(router) }
        }
    }

    private func reload() async {
        await store.load()
        if store.loaded { await model.load() }
    }

    private var sizePicker: some View {
        Picker("Photo size", selection: $size) {
            Text("S").tag("s"); Text("M").tag("m"); Text("L").tag("l")
        }
        .pickerStyle(.segmented)
        .frame(width: 120)
    }

    // MARK: the page

    @ViewBuilder private var content: some View {
        let s = store.summary
        VStack(alignment: .leading, spacing: 28) {
            if let h = hero { banner(h) }
            stats(s)
            if !model.today.ids.isEmpty {
                section(Hue.rose, "calendar", "On this day · \(Date().formatted(.dateTime.month(.wide).day()))",
                        link: ("See all", "#/photos?md=\(ExploreModel.monthDay)"))
                rows(model.today, limit: 8)
            }
            if !model.random.ids.isEmpty {
                section(Hue.indigo, "sparkles", "Rediscover", action: ("Shuffle", { Task { await model.shuffle() } }))
                rediscover
            }
            if !model.pairs.isEmpty {
                section(Hue.amber, "person.fill", "Then and now", action: ("Others", { Task { await model.loadPairs() } }))
                thenAndNow
            }
            if !store.places.isEmpty {
                section(Hue.green, "mappin.and.ellipse", "Places", link: ("See all", "#/places"))
                cards(store.places.prefix(12).map { p in
                    Card(id: p.id, image: p.cover.map { "thumb/\($0)" }, title: p.name,
                         sub: ([p.region, p.country].compactMap { $0 }.joined(separator: ", ") + " · " + n(p.count)),
                         route: "#/photos?" + Self.query(["place": p.name, "region": p.region, "country": p.country]))
                })
            }
            if !store.people.isEmpty {
                section(Hue.amber, "person.2.fill", "People", link: ("See all", "#/people"))
                people
            }
            if !model.trips.isEmpty {
                section(Hue.cyan, "map", "Trips", link: ("All events & trips", "#/events"))
                cards(model.trips.map { t in
                    Card(id: t.id, image: t.cover.map { "thumb/\($0)" }, title: t.title,
                         sub: "\(t.when) · \(n(t.count))\(t.days > 1 ? " · \(t.days) days" : "")",
                         route: "#/photos?" + Self.query(["from": t.from, "to": t.to, "sort": "old"]))
                })
            }
            if !model.concepts.isEmpty {
                section(Hue.purple, "sparkles", "Detected content", link: ("See all", "#/detected"))
                cards(model.concepts.map { c in
                    Card(id: c.name, image: c.cover.map { "thumb/\($0)" }, title: c.name.prefix(1).uppercased() + c.name.dropFirst(),
                         sub: n(c.count), route: "#/photos?" + Self.query(["concept": c.name]))
                })
            }
            if !s.things.isEmpty {
                section(Hue.orange, "tag.fill", "Things", link: ("All tags", "#/tags"))
                cards(s.things.map { t in
                    Card(id: "\(t.id)", image: t.cover.map { "thumb/\($0)" }, title: t.name, sub: n(t.count), route: "#/photos?tag=\(t.id)")
                })
            }
            section(Hue.cyan, "slider.horizontal.3", "Quick filters")
            pills(Hue.cyan, quickFilters(s))
            if !s.years.isEmpty {
                section(Hue.blue, "calendar", "Years")
                pills(Hue.blue, s.years.map { Pill(label: "\($0.0)", count: $0.1, route: "#/photos?year=\($0.0)") })
            }
            if !s.cameras.isEmpty {
                section(Hue.purple, "camera.fill", "Cameras")
                pills(Hue.purple, s.cameras.map { Pill(label: $0.0, count: $0.1, route: "#/photos?" + Self.query(["camera": $0.0])) })
            }
            if !s.creators.isEmpty {
                section(Hue.rose, "c.circle", "Photographers")
                pills(Hue.rose, s.creators.prefix(30).map { Pill(label: $0.0, count: $0.1, route: "#/photos?" + Self.query(["creator": $0.0])) })
            }
            if !s.formats.isEmpty {
                section(Hue.slate, "photo", "File types")
                pills(Hue.slate, s.formats.map { Pill(label: $0.0, count: $0.1, route: "#/photos?" + Self.query(["fmt": $0.0])) })
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 40)
        .frame(maxWidth: 1400)
        .frame(maxWidth: .infinity)
    }

    private var signIn: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("Sign in to iopix").font(.title3.bold())
            Text("Your library shows here once you're signed in.").foregroundStyle(.secondary)
            Button("Sign in") { signingIn = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
        .sheet(isPresented: $signingIn) { SignInView(changeServer: showUploads) }
    }

    private func unreachable(_ why: String) -> some View {
        VStack(spacing: 14) {
            Image("Mark").resizable().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14))
            Text("Can't reach iopix").font(.title3.bold())
            Text(why).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again") { Task { await reload() } }.buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .onReceive(NotificationCenter.default.publisher(for: .iopixBecameActive)) { _ in Task { await reload() } }
    }

    // MARK: the banner

    /// The photo at the top: one taken on this day in an earlier year, else a favorite, else a random one.
    private struct Hero { let list: PhotoList; let index: Int; let title: String; let subtitle: String }

    private var hero: Hero? {
        let t = model.today
        if !t.ids.isEmpty {
            // the widest of today's photos makes the best banner
            let i = (0..<t.ids.count).filter { !t.isVideo($0) }.max { t.ratio($0) < t.ratio($1) } ?? 0
            let ts = i < t.times.count ? t.times[i] : 0
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            let year = ts > 0 ? cal.component(.year, from: Date(timeIntervalSince1970: ts)) : 0
            let ago = Calendar.current.component(.year, from: Date()) - year
            return Hero(list: t, index: i, title: "On this day",
                        subtitle: year > 0 ? (ago == 1 ? "\(year) · a year ago" : "\(year) · \(ago) years ago") : Date().formatted(.dateTime.month(.wide).day()))
        }
        let r = model.random
        guard !r.ids.isEmpty else { return nil }
        let favs = (0..<r.ids.count).filter { store.favoriteIDs.contains(r.ids[$0]) }
        let i = favs.first ?? (0..<r.ids.count).max { r.ratio($0) < r.ratio($1) } ?? 0
        let ts = i < r.times.count ? r.times[i] : 0
        return Hero(list: r, index: i, title: favs.isEmpty ? "Rediscover" : "From your favorites",
                    subtitle: ts > 0 ? (r.dateText(i) ?? "") : "")
    }

    /// The banner's photo, blurred, behind the top of the page: a little colour from the library itself.
    @ViewBuilder private var wash: some View {
        if let h = hero {
            RemoteImage(path: "thumb/\(h.list.ids[h.index])")
                .frame(height: wide ? 560 : 420)
                .blur(radius: 60)
                .opacity(0.45)
                .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }

    private func banner(_ h: Hero) -> some View {
        Button { viewer = PagerStart(list: h.list, index: h.index) } label: {
            RemoteImage(path: "preview/\(h.list.ids[h.index])")
                .frame(maxWidth: .infinity)
                .frame(height: wide ? 380 : 240)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.title).font(.title2.bold())
                        if !h.subtitle.isEmpty { Text(h.subtitle).font(.subheadline) }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .contextMenu { photoMenu(h.list.ids[h.index]) }
        .accessibilityLabel("\(h.title), \(h.subtitle)")
    }

    // MARK: the numbers

    private func stats(_ s: LibrarySummary) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: wide ? 3 : 2), spacing: 10) {
            StatCard(hue: Hue.blue, symbol: "photo", value: n(s.total - s.videos), label: "photos") { router.open("#/photos") }
            StatCard(hue: Hue.purple, symbol: "video.fill", value: n(s.videos), label: "videos") { router.open("#/photos?type=video") }
            StatCard(hue: Hue.amber, symbol: "person.fill", value: n(store.people.count), label: "people") { router.open("#/people") }
            StatCard(hue: Hue.teal, symbol: "folder.fill", value: n(s.folders), label: "folders") { router.open("#/folders") }
            StatCard(hue: Hue.green, symbol: "mappin", value: n(s.geotagged), label: "with location") { router.open("#/map") }
            StatCard(hue: Hue.slate, symbol: "internaldrive", value: ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file), label: "on disk", action: nil)
        }
    }

    // MARK: rows of photos

    /// Rediscover, bigger than the other sections: one photo large (with four more beside it on a wide screen),
    /// then the rest in rows taller than On this day's. The banner's photo, when it came from here, is left out.
    @ViewBuilder private var rediscover: some View {
        let list = model.random
        let skip = hero.flatMap { $0.list.ids == list.ids ? $0.index : nil }
        let all = (0..<min(list.ids.count, 37)).filter { $0 != skip }
        // the big spot is wider than tall: a landscape photo fills it without losing half of itself
        if let first = all.first(where: { list.ratio($0) >= 1.2 }) ?? all.first {
            let others = all.filter { $0 != first }
            let side = Array(others.prefix(wide ? 4 : 0))
            let rest = Array(others.dropFirst(side.count))
            VStack(spacing: 4) {
                MosaicLayout(spacing: 4) {
                    tile(list, first, path: "preview/\(list.ids[first])")
                    ForEach(side, id: \.self) { tile(list, $0) }
                }
                .frame(height: rowHeight * (wide ? 2.6 : 2.2))
                JustifiedLayout(height: rowHeight * 1.3, spacing: 4, ratios: rest.map { list.ratio($0) }) {
                    ForEach(rest, id: \.self) { tile(list, $0) }
                }
            }
        }
    }

    private func tile(_ list: PhotoList, _ i: Int, path: String? = nil) -> some View {
        Button { viewer = PagerStart(list: list, index: i) } label: {
            RemoteImage(path: path ?? "thumb/\(list.ids[i])")
                .overlay { TileBadges(list: list, index: i, favorite: store.favoriteIDs.contains(list.ids[i])) }
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contextMenu { photoMenu(list.ids[i]) }
        .accessibilityLabel(list.dateText(i) ?? "Photo")
    }

    /// Right-click (Mac) or long-press on a photo, as in the Photos grid.
    @ViewBuilder private func photoMenu(_ id: Int) -> some View {
        let fav = store.favoriteIDs.contains(id)
        Button { Task { await store.setFavorite(id, !fav) } } label: {
            Label(fav ? "Remove from Favorites" : "Add to Favorites", systemImage: fav ? "heart.slash" : "heart")
        }
        Button { router.open("#/photos?p=\(id)") } label: { Label("Open in iopix", systemImage: "safari") }
    }

    private func rows(_ list: PhotoList, limit: Int) -> some View {
        let count = min(list.ids.count, limit)
        return JustifiedLayout(height: rowHeight, spacing: 4, ratios: (0..<count).map { list.ratio($0) }) {
            ForEach(0..<count, id: \.self) { i in
                Button { viewer = PagerStart(list: list, index: i) } label: {
                    RemoteImage(path: "thumb/\(list.ids[i])")
                        .overlay { TileBadges(list: list, index: i, favorite: store.favoriteIDs.contains(list.ids[i])) }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .contextMenu { photoMenu(list.ids[i]) }
                .accessibilityLabel(list.dateText(i) ?? "Photo")
            }
        }
    }

    // MARK: then and now

    private var thenAndNow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(model.pairs) { p in
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            face(p.then)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            face(p.now)
                        }
                        Button { router.open("#/photos?tag=\(p.tag)&sort=old") } label: {
                            (Text(p.name).bold() + Text(" · \(Self.years(p.years)) years apart").foregroundStyle(.secondary))
                                .font(.subheadline).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.25)))
                }
            }
        }
    }

    private func face(_ f: ThenNowPair.Face) -> some View {
        Button { viewer = PagerStart(list: PhotoList(ids: [f.photo], times: [f.ts]), index: 0) } label: {
            VStack(spacing: 4) {
                RemoteImage(path: "facecrop/\(f.photo)/" + f.rect.map(String.init).joined(separator: "/") + ".jpg")
                    .frame(width: wide ? 110 : 84, height: wide ? 110 : 84)
                    .clipShape(Circle())
                Text(Self.year(f.ts)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: people

    private var people: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(store.people.prefix(16)) { p in
                    Button { router.open("#/photos?tag=\(p.id)") } label: {
                        VStack(spacing: 6) {
                            FaceImage(person: p).frame(width: wide ? 96 : 76, height: wide ? 96 : 76).clipShape(Circle())
                            Text(p.name).font(.caption).lineLimit(1).frame(width: wide ? 110 : 86)
                            Text(n(p.all)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: cards and pills

    struct Card: Identifiable {
        let id: String, image: String?, title: String, sub: String, route: String
    }

    private func cards(_ list: [Card]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(list) { c in
                    Button { router.open(c.route) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Group {
                                if let img = c.image { RemoteImage(path: img) } else { Color.secondary.opacity(0.12) }
                            }
                            .frame(width: wide ? 200 : 150, height: wide ? 140 : 110)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(c.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(c.sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: wide ? 200 : 150, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    struct Pill: Identifiable {
        let label: String
        var count: Int? = nil
        let route: String
        var id: String { label + route }
    }

    private func quickFilters(_ s: LibrarySummary) -> [Pill] {
        var p = [Pill(label: "Videos", count: s.videos, route: "#/photos?type=video"),
                 Pill(label: "★★★★★", count: s.count(rating: 5), route: "#/photos?rating=5"),
                 Pill(label: "★★★ and up", count: s.threeAndUp, route: "#/photos?rating=3")]
        if let me = model.account?.person, let person = store.people.first(where: { $0.id == me }) {
            p.append(Pill(label: "Photos of me", count: person.all, route: "#/photos?tag=\(me)"))
        }
        p += [Pill(label: "Untagged", route: "#/photos?untagged=1"),
              Pill(label: "No location", count: s.total - s.geotagged, route: "#/photos?geo=0"),
              Pill(label: "Favorites", count: store.favorites, route: "#/photos?fav=1"),
              Pill(label: "Duplicate files", route: "#/duplicates"),
              Pill(label: "Events & trips", route: "#/events"),
              Pill(label: "Contains text", route: "#/photos?hastext=1"),
              Pill(label: "Blurry", route: "#/photos?blurry=1"),
              Pill(label: "Best looking", route: "#/photos?looks=top&sort=looks"),
              Pill(label: "Likely rejects", route: "#/photos?rejects=1")]
        if model.editing {
            p += [Pill(label: "Date suggestions", route: "#/datesuggest"), Pill(label: "Place suggestions", route: "#/placesuggest"),
                  Pill(label: "Jersey numbers", route: "#/jerseys"), Pill(label: "Clothing matches", route: "#/clothing")]
        }
        if model.editing && !model.noDigikam { p.append(Pill(label: "Edited here, not yet in digiKam", count: model.pending, route: "#/photos?edited=1")) }
        p.append(Pill(label: "Map", count: s.geotagged, route: "#/map"))
        return p
    }

    private func pills(_ hue: Color, _ list: [Pill]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(list) { p in
                Button { router.open(p.route) } label: {
                    HStack(spacing: 6) {
                        Text(p.label)
                        if let c = p.count { Text(n(c)).bold() }
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .foregroundStyle(hue)
                    .background(hue.opacity(0.13), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: section headings

    private func section(_ hue: Color, _ symbol: String, _ title: String, link: (String, String)? = nil,
                         action: (String, () -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(hue)
                .frame(width: 32, height: 32).background(hue.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
            Text(title).font(.title3.bold()).lineLimit(1)
            if let link { Button(link.0) { router.open(link.1) }.font(.subheadline) }
            if let action { Button(action.0, action: action.1).font(.subheadline) }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    // MARK: helpers

    private func n(_ v: Int) -> String { v.formatted() }

    static func query(_ items: [String: String?]) -> String {
        var c = URLComponents()
        c.queryItems = items.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        // URLComponents leaves "+" as it is, and the server reads a bare "+" as a space
        return (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    private static func years(_ y: Double) -> String { y.rounded() == y ? String(Int(y)) : String(format: "%.1f", y) }

    private static func year(_ ts: Double) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return String(cal.component(.year, from: Date(timeIntervalSince1970: ts)))
    }
}

/// A person's face picture, or their cover photo when they have no face picture.
struct FaceImage: View {
    let person: Person
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image { Color.clear.overlay(Image(uiImage: image).resizable().scaledToFill()).clipped() }
            else { Color.secondary.opacity(0.12) }
        }
        .task(id: person.id) {
            let face = "face/\(person.id)?v=\(person.icon ?? 0)"
            if let i = ImageCache.shared.cached(face) { image = i; return }
            image = await ImageCache.shared.image(face)
            if image == nil, let c = person.cover { image = await ImageCache.shared.image("thumb/\(c)") }
        }
    }
}

struct StatCard: View {
    let hue: Color, symbol: String, value: String, label: String
    let action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.headline).foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(hue, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 1) {
                    Text(value).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                    Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(hue.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hue.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

/// Photos in rows of the same height at their own shapes, each row filling the width (the last one may not).
struct JustifiedLayout: Layout {
    let height: CGFloat
    let spacing: CGFloat
    let ratios: [Double]

    private func rows(_ width: CGFloat, _ n: Int) -> [(range: Range<Int>, h: CGFloat)] {
        var out: [(Range<Int>, CGFloat)] = []
        var start = 0, sum = 0.0
        for i in 0..<n {
            sum += ratios.indices.contains(i) ? ratios[i] : 1.5
            let count = i - start + 1
            let natural = CGFloat(sum) * height + spacing * CGFloat(count - 1)
            if natural >= width {
                let h = max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(sum))  // a zero-width proposal: no negative heights
                out.append((start..<(i + 1), h))
                start = i + 1; sum = 0
            }
        }
        if start < n { out.append((start..<n, height)) }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 350
        let r = rows(w, subviews.count)
        return CGSize(width: w, height: r.reduce(0) { $0 + $1.h } + spacing * CGFloat(max(r.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews.count) {
            var x = bounds.minX
            for i in row.range {
                let w = CGFloat(ratios.indices.contains(i) ? ratios[i] : 1.5) * row.h
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: row.h))
                x += w + spacing
            }
            y += row.h + spacing
        }
    }
}

/// One large view on the left (all of it when it is alone), and up to four more in a square of two by two beside it.
struct MosaicLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 350, height: proposal.height ?? 300)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        let others = subviews.dropFirst()
        let bigW = others.isEmpty ? bounds.width : (bounds.width - spacing) * 0.6
        first.place(at: bounds.origin, proposal: ProposedViewSize(width: bigW, height: bounds.height))
        guard !others.isEmpty else { return }
        let colW = max(0, (bounds.width - bigW - spacing * 2) / 2)
        let rowH = max(0, (bounds.height - spacing) / 2)
        for (k, v) in others.enumerated() {
            let x = bounds.minX + bigW + spacing + CGFloat(k % 2) * (colW + spacing)
            let y = bounds.minY + CGFloat(k / 2) * (rowH + spacing)
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: colW, height: rowH))
        }
    }
}

/// Views side by side, wrapping onto new lines (the pill groups).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    private func lines(_ width: CGFloat, _ subviews: Subviews) -> [[(Int, CGSize)]] {
        var out: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { out.append([]); x = 0 }
            out[out.count - 1].append((i, s))
            x += s.width + spacing
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 350
        let l = lines(w, subviews)
        let h = l.map { $0.map(\.1.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(l.count - 1, 0))
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(bounds.width, subviews) {
            var x = bounds.minX
            let h = line.map(\.1.height).max() ?? 0
            for (i, s) in line {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += h + spacing
        }
    }
}
