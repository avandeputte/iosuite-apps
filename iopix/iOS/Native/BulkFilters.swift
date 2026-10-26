import SwiftUI

/// Counts for every filter, for the photos the current filters leave (the server's /api/facets).
struct Facets {
    var count = 0, videos = 0, geotagged = 0
    var tsMin: Double?, tsMax: Double?
    var iso: [Double?] = [], aperture: [Double?] = [], focal: [Double?] = []
    var tags: [(Int, Int)] = [], years: [(Int, Int)] = [], albums: [(Int, Int)] = []
    var cameras: [(String?, Int)] = [], lenses: [(String?, Int)] = [], formats: [(String?, Int)] = []
    var creators: [(String?, Int)] = [], objects: [(String?, Int)] = [], countries: [(String?, Int)] = []
    var picks: [(Int, Int)] = [], colors: [(Int, Int)] = [], npeople: [(Int, Int)] = []
    var places: [(city: String, region: String?, country: String?, n: Int)] = []
    var extras: [String: Int] = [:]

    init() {}

    init(_ j: [String: Any]) {
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func intPairs(_ k: String) -> [(Int, Int)] {
            (j[k] as? [[Any]] ?? []).compactMap { p in
                guard p.count >= 2, let a = (p[0] as? NSNumber)?.intValue, let n = (p[1] as? NSNumber)?.intValue else { return nil }
                return (a, n)
            }
        }
        func strPairs(_ k: String) -> [(String?, Int)] {
            (j[k] as? [[Any]] ?? []).compactMap { p in
                guard p.count >= 2, let n = (p[1] as? NSNumber)?.intValue else { return nil }
                return (p[0] as? String, n)
            }
        }
        count = (j["count"] as? NSNumber)?.intValue ?? 0
        videos = (j["videos"] as? NSNumber)?.intValue ?? 0
        geotagged = (j["geotagged"] as? NSNumber)?.intValue ?? 0
        tsMin = num(j["tsMin"]); tsMax = num(j["tsMax"])
        iso = (j["iso"] as? [Any] ?? []).map(num)
        aperture = (j["aperture"] as? [Any] ?? []).map(num)
        focal = (j["focal"] as? [Any] ?? []).map(num)
        tags = intPairs("tags"); years = intPairs("years"); albums = intPairs("albums")
        picks = intPairs("picks"); colors = intPairs("colors"); npeople = intPairs("npeople")
        cameras = strPairs("cameras"); lenses = strPairs("lenses"); formats = strPairs("formats")
        creators = strPairs("creators"); objects = strPairs("objects"); countries = strPairs("countries")
        places = (j["places"] as? [[Any]] ?? []).compactMap { p in
            guard p.count >= 4, let c = p[0] as? String, let n = (p[3] as? NSNumber)?.intValue else { return nil }
            return (c, p[1] as? String, p[2] as? String, n)
        }
        for (k, v) in j["extras"] as? [String: Any] ?? [:] { extras[k] = (v as? NSNumber)?.intValue ?? 0 }
    }
}

/// Every filter the web app's filter pane has, with how many photos each leaves. A choice applies at once; the
/// grid behind follows.
struct FilterSheet: View {
    @Binding var query: PhotoQuery
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = BulkCatalog.shared
    @State private var facets: Facets?
    @State private var problem: String?
    @State private var expanded: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                if let f = facets {
                    content(f)
                } else if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !query.filters.isEmpty {
                        Button("Clear all") { query = PhotoQuery(query.items.filter { $0.name == "sort" }) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: query.key) { await load() }
            .task { await catalog.load() }
        }
    }

    private func load() async {
        do {
            facets = Facets(try await IopixClient.shared.json("api/facets", query: query.filters))
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: the sections, in the web app's order

    @ViewBuilder private func content(_ f: Facets) -> some View {
        Section { Text("\(f.count.formatted()) items").foregroundStyle(.secondary) }
        Section("Type") {
            row("Photos", f.count - f.videos, on: query.value("type") == "photo") { query = query.choosing("type", "photo") }
            row("Videos", f.videos, on: query.value("type") == "video") { query = query.choosing("type", "video") }
        }
        Section("Rating at least") { stars }
        Section("Date") { dates(f) }
        section("Year", f.years.map { y in Row(id: "y\(y.0)", label: String(y.0), count: y.1, on: query.has("year", String(y.0))) { query = query.toggling("year", String(y.0)) } }, limit: 6)
        section("People", tagRows(f, person: true))
        section("Tags", tagRows(f, person: false) + [Row(id: "untagged", label: "Untagged", count: nil, on: query.value("untagged") == "1") { query = query.choosing("untagged", "1") }])
        section("Folder", f.albums.compactMap { a in
            catalog.folderByID[a.0].map { folder in
                Row(id: "a\(a.0)", label: String(folder.path.drop { $0 == "/" }).isEmpty ? folder.name : String(folder.path.drop { $0 == "/" }), count: a.1,
                    on: query.has("album", String(a.0))) { query = query.toggling("album", String(a.0)) }
            }
        }, limit: 6)
        Section("Location") {
            row("Favorites", nil, on: query.value("fav") == "1", symbol: "heart") { query = query.choosing("fav", "1") }
            row("Has location", f.geotagged, on: query.value("geo") == "1") { query = query.choosing("geo", "1") }
            row("No location", f.count - f.geotagged, on: query.value("geo") == "0") { query = query.choosing("geo", "0") }
        }
        section("Country", f.countries.compactMap { c in
            c.0.map { name in Row(id: "c\(name)", label: name, count: c.1, on: query.has("country", name)) { query = query.toggling("country", name) } }
        }, limit: 5)
        section("Place", f.places.map { p in
            Row(id: "p\(p.city)|\(p.region ?? "")", label: p.city + (p.region.map { ", \($0)" } ?? ""), count: p.n, on: query.value("place") == p.city) {
                if query.value("place") == p.city { query = query.setting("place", nil).setting("region", nil) }
                else { query = query.setting("place", p.city).setting("region", p.region) }
            }
        })
        section("Camera", f.cameras.map { c in
            let v = c.0 ?? "~"
            return Row(id: "cam\(v)", label: c.0 ?? "Unknown camera", count: c.1, on: query.has("camera", v)) { query = query.toggling("camera", v) }
        }, limit: 6)
        section("Lens", f.lenses.compactMap { l in
            l.0.map { name in Row(id: "lens\(name)", label: name, count: l.1, on: query.has("lens", name)) { query = query.toggling("lens", name) } }
        }, limit: 6)
        section("Labels", labelRows(f), limit: 12)
        section("Quality", qualityRows(f), limit: 9)
        if (f.extras["bursts"] ?? 0) > 0 {
            Section("Bursts") {
                row("In a burst", f.extras["bursts"], on: query.value("bursts") == "1") { query = query.choosing("bursts", "1") }
                row("Show only the best frame of each burst", nil, on: query.value("bestonly") == "1") { query = query.choosing("bestonly", "1") }
            }
        }
        section("People in the picture", peopleCountRows(f), limit: 8)
        section("Objects", f.objects.compactMap { o in
            o.0.map { name in Row(id: "o\(name)", label: name, count: o.1, on: query.has("obj", name)) { query = query.toggling("obj", name) } }
        }, limit: 8)
        Section("Exposure") {
            RangeRow(label: "ISO", key: "iso", bounds: f.iso, query: $query)
            RangeRow(label: "Aperture ƒ/", key: "ap", bounds: f.aperture, query: $query)
            RangeRow(label: "Focal mm", key: "fl", bounds: f.focal, query: $query)
        }
        section("Photographer", f.creators.compactMap { c in
            c.0.map { name in Row(id: "cr\(name)", label: name, count: c.1, on: query.has("creator", name)) { query = query.toggling("creator", name) } }
        }, limit: 5)
        section("File type", f.formats.compactMap { x in
            x.0.map { name in Row(id: "f\(name)", label: name, count: x.1, on: query.has("fmt", name)) { query = query.toggling("fmt", name) } }
        }, limit: 10)
    }

    private struct Row: Identifiable {
        let id: String, label: String, count: Int?, on: Bool
        var face: Int? = nil
        let toggle: () -> Void
    }

    private func tagRows(_ f: Facets, person: Bool) -> [Row] {
        f.tags.compactMap { t in
            guard let tag = catalog.tagByID[t.0], tag.person == person else { return nil }
            return Row(id: "t\(t.0)", label: person ? tag.name : tag.shortPath, count: t.1, on: query.has("tag", String(t.0)),
                       face: person ? t.0 : nil) { query = query.toggling("tag", String(t.0)) }
        }
    }

    private func labelRows(_ f: Facets) -> [Row] {
        let pickNames = ["No pick label", "Rejected", "Pending", "Accepted"]
        let picks = f.picks.filter { $0.0 > 0 }.map { p in
            Row(id: "pk\(p.0)", label: "Pick: " + pickNames[min(max(p.0, 0), 3)], count: p.1, on: query.has("pick", String(p.0))) { query = query.toggling("pick", String(p.0)) }
        }
        let colors = f.colors.filter { $0.0 > 0 }.map { c in
            Row(id: "cl\(c.0)", label: "Colour: " + BulkCatalog.colorNames[min(max(c.0, 0), 9)], count: c.1, on: query.has("color", String(c.0))) { query = query.toggling("color", String(c.0)) }
        }
        return picks + colors
    }

    private func qualityRows(_ f: Facets) -> [Row] {
        var out: [Row] = []
        func add(_ extra: String, _ label: String, _ key: String, _ value: String) {
            guard let n = f.extras[extra], n > 0 else { return }
            out.append(Row(id: "q\(extra)", label: label, count: n, on: query.value(key) == value) { query = query.choosing(key, value) })
        }
        add("sharpest", "Sharpest fifth", "sharpest", "1")
        add("blurry", "Blurry (least sharp tenth)", "blurry", "1")
        add("dark", "Very dark", "exposure", "dark")
        add("bright", "Very bright", "exposure", "bright")
        add("hastext", "Contains text", "hastext", "1")
        // photo quality (iopix 1.81): suggestions only, nothing is marked until someone marks it
        add("looks", "Best looking tenth", "looks", "top")
        add("eyes", "Someone's eyes closed", "eyes", "closed")
        add("rejects", "Likely rejects", "rejects", "1")
        if (f.extras["rejects"] ?? 0) > 0 {
            for (k, l) in [("blur", "Blurry all over"), ("eyes", "Eyes closed"), ("burst", "Worse frame of a burst"), ("exposure", "Nearly black or blown out")] {
                guard let n = f.extras["reject_" + k], n > 0 else { continue }
                out.append(Row(id: "qr\(k)", label: "↳ " + l, count: n, on: query.has("reject", k)) { query = query.toggling("reject", k) })
            }
        }
        return out
    }

    private func peopleCountRows(_ f: Facets) -> [Row] {
        var buckets: [(String, Int)] = []
        for (n, c) in f.npeople.sorted(by: { $0.0 < $1.0 }) {
            let k = n >= 5 ? "5+" : String(n)
            if let i = buckets.firstIndex(where: { $0.0 == k }) { buckets[i].1 += c } else { buckets.append((k, c)) }
        }
        return buckets.map { k, c in
            Row(id: "np\(k)", label: k == "0" ? "No people" : k == "1" ? "1 person" : "\(k) people", count: c, on: query.value("npeople") == k) {
                query = query.choosing("npeople", k)
            }
        }
    }

    // MARK: building blocks

    @ViewBuilder private func section(_ title: String, _ rows: [Row], limit: Int = 8) -> some View {
        if !rows.isEmpty {
            let open = expanded.contains(title)
            Section {
                ForEach(open ? rows : Array(rows.prefix(limit))) { r in
                    row(r.label, r.count, on: r.on, face: r.face, action: r.toggle)
                }
                if rows.count > limit {
                    Button(open ? "Show less" : "All \(rows.count)") {
                        if open { expanded.remove(title) } else { expanded.insert(title) }
                    }
                }
            } header: { Text(title) }
        }
    }

    private func row(_ label: String, _ count: Int?, on: Bool, symbol: String? = nil, face: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let face {
                    RemoteImage(path: "face/\(face)?v=\(catalog.tagByID[face]?.icon ?? 0)").frame(width: 28, height: 28).clipShape(Circle())
                } else if let symbol {
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
                Text(label).foregroundStyle(.primary).lineLimit(2)
                Spacer()
                if let count { Text(count.formatted()).foregroundStyle(.secondary).font(.subheadline) }
                if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var stars: some View {
        let rating = Int(query.value("rating") ?? "") ?? 0
        return HStack(spacing: 14) {
            ForEach(1...5, id: \.self) { n in
                Button { query = query.choosing("rating", String(n)) } label: {
                    Image(systemName: n <= rating ? "star.fill" : "star").font(.title3).foregroundStyle(n <= rating ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(n) star\(n > 1 ? "s" : "") and up")
            }
            Spacer()
            if rating > 0 { Button("Any") { query = query.setting("rating", nil) }.buttonStyle(.borderless) }
        }
    }

    @ViewBuilder private func dates(_ f: Facets) -> some View {
        DateFilterRow(label: "From", key: "from", fallback: f.tsMin, query: $query)
        DateFilterRow(label: "Until", key: "to", fallback: f.tsMax, query: $query)
    }
}

/// A day the photos start or end at (from=, to= as YYYY-MM-DD), or none.
private struct DateFilterRow: View {
    let label: String, key: String
    let fallback: Double?
    @Binding var query: PhotoQuery

    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        let current = query.value(key).flatMap { Self.format.date(from: $0) }
        HStack {
            Text(label)
            Spacer()
            if let current {
                DatePicker(label, selection: Binding(get: { current }, set: { query = query.setting(key, Self.format.string(from: $0)) }), displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                Button { query = query.setting(key, nil) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear \(label)")
            } else {
                Button("Any day") {
                    let d = fallback.map { Date(timeIntervalSince1970: $0) } ?? Date()
                    query = query.setting(key, Self.format.string(from: d))
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

/// At least / at most for a camera setting (iso_min, iso_max...).
private struct RangeRow: View {
    let label: String, key: String
    let bounds: [Double?]
    @Binding var query: PhotoQuery
    @State private var low = ""
    @State private var high = ""

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            field("min", $low, bounds.first ?? nil)
            Text("–").foregroundStyle(.secondary)
            field("max", $high, bounds.count > 1 ? bounds[1] : nil)
        }
        .onAppear { sync() }
        .onChange(of: query.key) { _, _ in sync() }  // a chip's cross or Clear all took the value away
    }

    private func sync() {
        let lo = query.value("\(key)_min") ?? "", hi = query.value("\(key)_max") ?? ""
        if Double(low.replacingOccurrences(of: ",", with: ".")) != Double(lo) { low = lo }
        if Double(high.replacingOccurrences(of: ",", with: ".")) != Double(hi) { high = hi }
    }

    private func field(_ which: String, _ text: Binding<String>, _ hint: Double?) -> some View {
        TextField(hint.map { which + " " + Self.short($0) } ?? which, text: text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 84)
            .textFieldStyle(.roundedBorder)
            .onSubmit { apply(which, text.wrappedValue) }
            .onChange(of: text.wrappedValue) { _, v in
                if v.isEmpty || Double(v.replacingOccurrences(of: ",", with: ".")) != nil { apply(which, v) }
            }
    }

    private func apply(_ which: String, _ v: String) {
        let clean = v.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        let next = query.setting("\(key)_\(which)", clean.isEmpty ? nil : clean)
        if next.key != query.key { query = next }
    }

    private static func short(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v) }
}
