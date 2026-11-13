import SwiftUI
import MapKit

/// Lower case without accents, to match a typed filter ("Zurich" finds Zürich), as the web app's `norm`.
private func norm(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil) }

private func plural(_ n: Int, _ word: String) -> String { "\(n.formatted()) \(word)\(n == 1 ? "" : "s")" }

// MARK: - Places

/// Where photos were taken: a map with photos gathered as you zoom out, or the places by country, then region,
/// then town (as the web app's Places page).
struct PlacesScreen: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var router: Router
    @State private var find = ""

    var body: some View {
        Group {
            if router.placesShowsMap {
                PhotoMap(query: router.mapQuery, clearFilter: router.mapQuery.items.isEmpty ? nil : { router.mapQuery = PhotoQuery() })
                    .id(router.mapQuery)  // another filter: a map loaded afresh
                    .ignoresSafeArea(edges: .bottom)
            } else {
                placeList
            }
        }
        .hardTopEdge()
        .navigationTitle(router.placesShowsMap ? "Places" : router.placesRegion ?? router.placesCountry ?? "Places")
        .navigationBarTitleDisplayMode(.inline)
        .globalSearch()
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $router.placesShowsMap) {
                    Text("Map").tag(true); Text("Places").tag(false)
                }
                .pickerStyle(.segmented).frame(width: 200)
            }
        }
        .onChange(of: level) { _, _ in find = "" }
    }

    /// A row of the list: a country with its regions, a region with its towns, or a town.
    private struct Row: Identifiable {
        let name: String
        var count = 0, cover: Int?, top = 0
        var kids: Set<String> = []
        var place: Place
        var id: String { name }
    }

    /// Which part of a place names the rows: 2 the country, 1 the region, 0 the town.
    private var level: Int { router.placesCountry == nil ? 2 : router.placesRegion == nil ? 1 : 0 }

    /// The places under the country and region on show. A place without one is filed under "Other".
    private var rows: [Place] {
        store.places.filter { p in
            (router.placesCountry == nil || (p.country ?? "Other") == router.placesCountry)
                && (router.placesRegion == nil || (p.region ?? "Other") == router.placesRegion)
        }
    }

    private var groups: [Row] {
        var by: [String: Row] = [:]
        for p in rows {
            let key = level == 0 ? p.name : level == 1 ? (p.region ?? "Other") : (p.country ?? "Other")
            var g = by[key] ?? Row(name: key, cover: p.cover, place: p)
            g.count += p.count
            g.kids.insert(level == 2 ? (p.region ?? "Other") : p.name)
            if p.count > g.top { g.top = p.count; g.cover = p.cover }  // the picture of its busiest place
            by[key] = g
        }
        return by.values.sorted { $0.count > $1.count }
    }

    /// The filter for every photo of the level on show (a country, or a region of it).
    private var here: PhotoQuery {
        var q: [(String, String)] = []
        if let c = router.placesCountry { q.append(("country", c)) }
        if let r = router.placesRegion, r != "Other" { q.append(("region", r)) }
        return PhotoQuery(q)
    }

    private var placeList: some View {
        let f = norm(find.trimmingCharacters(in: .whitespaces))
        let shown = groups.filter { f.isEmpty || norm($0.name).contains(f) }
        let total = rows.reduce(0) { $0 + $1.count }
        return List {
            if store.places.isEmpty {
                Text("No place names yet. ioPix names places from the photos' locations.").foregroundStyle(.secondary)
            } else {
                Section {
                    if level < 2 { crumbs }
                    Text(level == 2 ? "Countries where your geotagged photos were taken. Open one to see its regions, then towns. Names come from each photo’s GPS position, worked out offline."
                         : level == 1 ? "Regions of \(router.placesCountry ?? "")." : "Towns in \(router.placesRegion ?? ""), \(router.placesCountry ?? "").")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField(level == 2 ? "Find a country…" : level == 1 ? "Find a region…" : "Find a town…", text: $find)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    if level < 2 {
                        HStack {
                            Button { router.push(.photos(here, title: router.placesRegion ?? router.placesCountry)) } label: {
                                Label("All \(total.formatted()) photos here", systemImage: "photo")
                            }
                            Button { router.mapQuery = here; router.placesShowsMap = true } label: { Label("Map", systemImage: "map") }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Section {
                    ForEach(shown) { g in
                        Button { open(g) } label: { ThumbRow(cover: g.cover, title: g.name, sub: sub(g)) }
                            .buttonStyle(.plain)
                    }
                    if shown.isEmpty { Text("No places match.").foregroundStyle(.secondary) }
                }
            }
        }
    }

    /// The way here: Places › country › region. Tap an earlier step to go back to it.
    private var crumbs: some View {
        HStack(spacing: 4) {
            Button("Places") { router.placesCountry = nil; router.placesRegion = nil }
            if let c = router.placesCountry {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                if router.placesRegion == nil { Text(c) } else { Button(c) { router.placesRegion = nil } }
            }
            if let r = router.placesRegion {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                Text(r)
            }
        }
        .font(.subheadline).lineLimit(1)
    }

    private func sub(_ g: Row) -> String {
        switch level {
        case 2: return "\(g.count.formatted()) · \(plural(g.kids.count, "region"))"
        case 1: return "\(g.count.formatted()) · \(plural(g.kids.count, "town"))"
        default: return g.count.formatted()
        }
    }

    private func open(_ g: Row) {
        switch level {
        case 2: router.placesCountry = g.name
        case 1: router.placesRegion = g.name
        default:
            var q: [(String, String)] = [("place", g.name)]
            if let r = g.place.region { q.append(("region", r)) }
            if let c = g.place.country { q.append(("country", c)) }
            router.push(.photos(PhotoQuery(q), title: g.name))
        }
    }
}

/// A row with a small picture, a name and a line under it.
struct ThumbRow: View {
    let cover: Int?
    let title: String
    let sub: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let cover { RemoteImage(path: "thumb/\(cover)") }
                else { Color.secondary.opacity(0.12).overlay(Image(systemName: symbol ?? "photo").foregroundStyle(.secondary)) }
            }
            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).lineLimit(1)
                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Map

/// Every photo with a location on a map, gathered into bubbles that split as you zoom in. Tap a bubble to open its
/// photos or zoom to it. With a `query` the map shows only the photos matching it ("Show these on the map"), and
/// with trail= in it, a day's route through them. Editors can put photos without a location on the map.
struct PhotoMap: View {
    var query = PhotoQuery()
    /// The caller's own way to open the photos of a box ("south,west,north,east"); without it, they open on top of
    /// the map in its tab.
    var open: ((String) -> Void)? = nil
    /// Takes the filter off (the map in Places); nil when the map has none.
    var clearFilter: (() -> Void)? = nil

    @EnvironmentObject private var router: Router
    @StateObject private var model = MapModel()
    @StateObject private var rights = ManageRights()
    @AppStorage("map-layer") private var layer = "map"  // remembered, as the web app does
    @State private var find = ""
    @State private var found: [AppleSearch.Place] = []
    @State private var note: String?

    var body: some View {
        MapCanvas(model: model, layer: layer)
            .overlay(alignment: .top) { topBar }
            .overlay(alignment: .bottom) { bottomBar }
            .confirmationDialog("Photos here", isPresented: Binding(get: { model.choice != nil }, set: { if !$0 { model.choice = nil } }),
                                titleVisibility: .hidden, presenting: model.choice) { s in
                Button("Open all \(s.count.formatted()) photos") { openAll(s) }
                Button("Zoom in") { model.zoom(to: s) }
                Button("Cancel", role: .cancel) {}
            }
            .task {
                await rights.load()
                await model.load(query)
            }
    }

    private var pill: some ShapeStyle { .regularMaterial }

    /// Find a place, and the Map / Satellite / Hybrid choice.
    private var topBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a place, e.g. Amsterdam", text: $find)
                        .textFieldStyle(.plain).autocorrectionDisabled().submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    if !find.isEmpty {
                        Button { find = ""; found = []; note = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8).background(pill, in: Capsule())
                Menu {
                    Picker("Layer", selection: $layer) {
                        Text("Map").tag("map"); Text("Satellite").tag("satellite"); Text("Hybrid").tag("hybrid")
                    }
                } label: {
                    Image(systemName: "square.3.layers.3d").padding(10).background(pill, in: Circle())
                }
            }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6).background(pill, in: Capsule())
            }
            // the matches: Enter went to the first, the others are here to pick
            if found.count > 1 {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(found.prefix(6).enumerated()), id: \.offset) { _, p in
                        Button { go(to: p) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "mappin").foregroundStyle(.secondary)
                                Text(p.name) + Text(p.detail.isEmpty ? "" : " · \(p.detail)").foregroundStyle(.secondary)
                            }
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(pill, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    /// What the map shows, the photos of the area on screen, and placing photos.
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = model.toast {
                HStack {
                    Text(t.text).font(.subheadline)
                    if let undo = t.undo { Button("Undo") { Task { await undo() } }.font(.subheadline.bold()) }
                }
                .padding(.horizontal, 14).padding(.vertical, 8).background(pill, in: Capsule())
                .task(id: t.id) { try? await Task.sleep(nanoseconds: 8_000_000_000); if model.toast?.id == t.id { model.toast = nil } }
            }
            if model.placing { tray }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let t = model.trail { Text(t).font(.footnote).padding(.horizontal, 12).padding(.vertical, 7).background(pill, in: Capsule()) }
                    if let clearFilter, !query.filters.isEmpty {
                        Button { clearFilter() } label: { Label("Filtered · Clear", systemImage: "xmark") }
                            .font(.footnote).padding(.horizontal, 12).padding(.vertical, 7).background(pill, in: Capsule())
                    }
                    Text("\(model.count.formatted()) with location").font(.footnote).padding(.horizontal, 12).padding(.vertical, 7).background(pill, in: Capsule())
                    Button {
                        guard let b = model.visibleBox() else { return }
                        openPhotos(query.setting("trail", nil).setting("ids", nil).setting("bbox", b), title: "This area")
                    } label: { Label("Show photos in this area", systemImage: "photo") }
                        .font(.footnote).padding(.horizontal, 12).padding(.vertical, 7).background(pill, in: Capsule())
                    if rights.canWrite {
                        Button { Task { await model.togglePlacing(query) } } label: {
                            Label(model.placing ? "Done placing" : "Place photos", systemImage: "mappin.and.ellipse")
                        }
                        .font(.footnote).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(model.placing ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(pill), in: Capsule())
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.bottom, 8)
    }

    /// The photos without a location: pick some, then tap the map (or the pin of a place found) where they were taken.
    private var tray: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.selected.isEmpty ? "\(model.unplaced.count.formatted()) without a location" : "\(model.selected.count.formatted()) selected").bold()
                Spacer()
                Button("Select shown") { model.selected = Set(model.unplaced) }
                Button("Clear") { model.selected = [] }
            }
            .font(.subheadline)
            Text(model.selected.isEmpty ? "Tap photos to select them, then tap the map where they were taken." : "Tap the map where they were taken.")
                .font(.caption).foregroundStyle(.secondary)
            if model.unplaced.isEmpty {
                Text(model.loadingTray ? "Loading the photos without a location…" : "Every photo has a location.").font(.caption).foregroundStyle(.secondary)
            } else {
                ManageThumbStrip(items: model.unplaced.map { .init(id: $0, selected: model.selected.contains($0)) }, height: 70) { i in
                    let id = model.unplaced[i]
                    if model.selected.contains(id) { model.selected.remove(id) } else { model.selected.insert(id) }
                }
            }
        }
        .padding(10).background(pill, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 8)
    }

    private func search() async {
        let q = find.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        note = nil
        do {
            found = try await AppleSearch.places(q)
            if let first = found.first { go(to: first, keepList: true) } else { note = "Nothing found." }
        } catch { found = []; note = AppleSearch.message(error) }
    }

    /// The map goes to a place found, with a pin until the next search.
    private func go(to p: AppleSearch.Place, keepList: Bool = false) {
        find = p.name
        if !keepList { found = [] }
        model.pin(at: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), title: p.name)
    }

    /// A bubble's photos: by their ids when few, else by their box (the web app's limit, so the address stays short).
    private func openAll(_ s: MapModel.Spot) {
        var q = query.setting("trail", nil).setting("bbox", nil).setting("ids", nil)
        if s.ids.count <= 600 {
            q = q.setting("ids", s.ids.map(String.init).joined(separator: ","))
        } else {
            let pad = 0.0001
            q = q.setting("bbox", [s.box.minLat - pad, s.box.minLon - pad, s.box.maxLat + pad, s.box.maxLon + pad].map { String(format: "%.5f", $0) }.joined(separator: ","))
        }
        openPhotos(q, title: "This area")
    }

    private func openPhotos(_ q: PhotoQuery, title: String) {
        if let open, q.items.count == 1, let b = q.value("bbox") { open(b) } else { router.push(.photos(q, title: title)) }
    }
}

/// The MapKit view of the map: its delegate work goes to the model.
private struct MapCanvas: UIViewRepresentable {
    let model: MapModel
    let layer: String

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.register(Bubble.self, forAnnotationViewWithReuseIdentifier: "bubble")
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "mark")
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        model.map = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.mapType = layer == "satellite" ? .satellite : layer == "hybrid" ? .hybrid : .standard
    }

    final class Bubble: MKAnnotationView {
        private let photo = UIImageView()
        private let label = UILabel()

        override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
            super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
            frame = CGRect(x: 0, y: 0, width: 52, height: 52)
            photo.frame = bounds.insetBy(dx: 2, dy: 2)
            photo.contentMode = .scaleAspectFill
            photo.clipsToBounds = true
            photo.layer.cornerRadius = 10
            photo.backgroundColor = .secondarySystemFill
            layer.cornerRadius = 12
            backgroundColor = .white
            layer.shadowOpacity = 0.3; layer.shadowRadius = 3; layer.shadowOffset = .zero
            label.font = .boldSystemFont(ofSize: 11)
            label.textColor = .white
            label.backgroundColor = UIColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1)
            label.textAlignment = .center
            label.layer.cornerRadius = 9
            label.clipsToBounds = true
            addSubview(photo)
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError() }

        func show(_ s: MapModel.Spot) {
            label.text = s.count > 999 ? "\(s.count / 1000)k" : "\(s.count)"
            label.sizeToFit()
            let w = max(18, label.bounds.width + 10)
            label.frame = CGRect(x: bounds.width - w + 6, y: -6, width: w, height: 18)
            photo.image = ImageCache.shared.cached("thumb/\(s.cover)")
            if photo.image == nil {
                let id = s.cover
                Task { @MainActor in
                    let img = await ImageCache.shared.image("thumb/\(id)")
                    if (self.annotation as? MapModel.Spot)?.cover == id { self.photo.image = img }
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        let model: MapModel

        init(_ model: MapModel) { self.model = model }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) { model.regroup() }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let s = annotation as? MapModel.Spot {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "bubble", for: s) as? Bubble
                v?.annotation = s
                v?.show(s)
                return v
            }
            if let m = annotation as? MapModel.Mark {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "mark", for: m) as? MKMarkerAnnotationView
                v?.markerTintColor = m.color
                v?.displayPriority = .required
                return v
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            mapView.deselectAnnotation(annotation, animated: false)
            if let s = annotation as? MapModel.Spot { model.choose(s) }
            else if let m = annotation as? MapModel.Mark, m.takesPhotos { model.tapped(m.coordinate) }  // the pin of a place found
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let r = MKPolylineRenderer(overlay: overlay)
            r.strokeColor = UIColor.systemRed.withAlphaComponent(0.8)
            r.lineWidth = 3
            r.lineDashPattern = [6, 6]
            return r
        }

        /// A tap on the map itself (not on a bubble or pin) while placing photos: they go there.
        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MKMapView, model.placing else { return }
            let at = g.location(in: map)
            var hit = map.hitTest(at, with: nil)
            while let v = hit { if v is MKAnnotationView { return }; hit = v.superview }
            model.tapped(map.convert(at, toCoordinateFrom: map))
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// The map's photos and what is done with them; the view it draws on is MapKit's.
@MainActor
final class MapModel: ObservableObject {
    final class Spot: NSObject, MKAnnotation {
        let coordinate: CLLocationCoordinate2D
        let count: Int, cover: Int, ids: [Int]
        let box: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)
        init(_ c: CLLocationCoordinate2D, cover: Int, ids: [Int], box: (Double, Double, Double, Double)) {
            coordinate = c; count = ids.count; self.cover = cover; self.ids = ids; self.box = box
        }
    }

    /// A pin that is not a photo: a place found, the start or end of a trail.
    final class Mark: MKPointAnnotation {
        var color = UIColor.systemBlue
        var takesPhotos = false
    }

    struct Toast: Identifiable {
        let id = UUID()
        let text: String
        var undo: (() async -> Void)? = nil
    }

    weak var map: MKMapView?
    @Published var count = 0
    /// The day's route, in words ("Trail: 12 photos, 3 km, 09:10 to 17:40").
    @Published var trail: String?
    /// A bubble tapped: open its photos, or zoom in?
    @Published var choice: Spot?
    @Published var toast: Toast?
    @Published var placing = false
    @Published var loadingTray = false
    /// Photos without a location (placing), and the ones picked.
    @Published var unplaced: [Int] = []
    @Published var selected: Set<Int> = []
    private var points: [(id: Int, lat: Double, lon: Double)] = []
    private var pin: Mark?
    private var query = PhotoQuery()

    func load(_ query: PhotoQuery) async {
        self.query = query
        guard let j = try? await IopixClient.shared.json("api/map", query: query.items) else { return }
        let ids = j["id"] as? [Any] ?? [], lats = j["lat"] as? [Any] ?? [], lons = j["lon"] as? [Any] ?? []
        var pts: [(Int, Double, Double)] = []
        for i in 0..<min(ids.count, lats.count, lons.count) {
            guard let id = (ids[i] as? NSNumber)?.intValue, let la = (lats[i] as? NSNumber)?.doubleValue,
                  let lo = (lons[i] as? NSNumber)?.doubleValue else { continue }
            pts.append((id, la, lo))
        }
        points = pts
        count = pts.count
        guard let map, !pts.isEmpty else { return }
        // start on where most photos are: the middle 90% of them
        let la = pts.map(\.1).sorted(), lo = pts.map(\.2).sorted()
        let a = Int(Double(pts.count) * 0.05), b = max(a, Int(Double(pts.count) * 0.95) - 1)
        // never wider than the world: MapKit throws on a span past 180° of latitude or 360° of longitude
        let span = MKCoordinateSpan(latitudeDelta: min(170, max(0.05, (la[b] - la[a]) * 1.3)), longitudeDelta: min(360, max(0.05, (lo[b] - lo[a]) * 1.3)))
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (la[a] + la[b]) / 2, longitude: (lo[a] + lo[b]) / 2), span: span), animated: false)
        regroup()
        // a day's trail (trail=, or from= and to= the same day): the route through its photos
        if let day = query.value("trail") ?? (query.value("from") != nil && query.value("from") == query.value("to") ? query.value("from") : nil) {
            await loadTrail(day)
        }
    }

    private func loadTrail(_ day: String) async {
        guard let map, let t = try? await IopixClient.shared.json("api/trail", query: [URLQueryItem(name: "day", value: day)]) else { return }
        let lats = (t["lat"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        let lons = (t["lon"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        let ts = (t["ts"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        let n = min(lats.count, lons.count)
        guard n >= 2 else { return }
        let pts = (0..<n).map { CLLocationCoordinate2D(latitude: lats[$0], longitude: lons[$0]) }
        map.addOverlay(MKPolyline(coordinates: pts, count: n))
        let time: (Int) -> String = { i in i < ts.count ? Date(timeIntervalSince1970: ts[i]).formatted(date: .omitted, time: .shortened) : "" }
        let start = Mark(), end = Mark()
        start.coordinate = pts[0]; start.title = "Start · \(time(0))"; start.color = .systemGreen
        end.coordinate = pts[n - 1]; end.title = "End · \(time(n - 1))"; end.color = .systemRed
        map.addAnnotations([start, end])
        // the length of the route, as the web app counts it: straight lines between the photos
        var km = 0.0
        for i in 1..<n {
            km += hypot(lats[i] - lats[i - 1], (lons[i] - lons[i - 1]) * cos(lats[i] * .pi / 180)) * 111.2
        }
        trail = "Trail: \(plural(n, "photo")), \(EditLocationSheet.distance(km * 1000)), \(time(0)) to \(time(n - 1))"
        map.setVisibleMapRect(MKPolyline(coordinates: pts, count: n).boundingMapRect, edgePadding: UIEdgeInsets(top: 80, left: 40, bottom: 120, right: 40), animated: true)
    }

    /// Bubbles of about 84 points across for what is on screen (a bubble is 52 wide, so they rarely overlap).
    func regroup() {
        guard let map, map.bounds.width > 0, map.bounds.height > 0 else { return }
        let r = map.region
        let cellLat = r.span.latitudeDelta * 84 / Double(map.bounds.height)
        let cellLon = r.span.longitudeDelta * 84 / Double(map.bounds.width)
        guard cellLat > 0, cellLon > 0, cellLat.isFinite, cellLon.isFinite else { return }  // a span of nothing: no cells to put photos in
        let minLat = r.center.latitude - r.span.latitudeDelta, maxLat = r.center.latitude + r.span.latitudeDelta
        let minLon = r.center.longitude - r.span.longitudeDelta, maxLon = r.center.longitude + r.span.longitudeDelta
        // a view across the date line (or most of the world) takes every longitude: a plain range would miss the far side
        let allLon = minLon < -180 || maxLon > 180
        struct Cell { var ids: [Int] = [], cover = 0, lat = 0.0, lon = 0.0, a = 90.0, b = 180.0, c = -90.0, d = -180.0 }
        struct Key: Hashable { let row: Int, col: Int }  // two numbers, not one made of both: no two cells share a key
        var cells: [Key: Cell] = [:]
        for p in points where p.lat >= minLat && p.lat <= maxLat && (allLon || (p.lon >= minLon && p.lon <= maxLon)) {
            let key = Key(row: Int((p.lat / cellLat).rounded(.down)), col: Int((p.lon / cellLon).rounded(.down)))
            var c = cells[key] ?? Cell(cover: p.id)
            c.ids.append(p.id); c.lat += p.lat; c.lon += p.lon
            c.a = min(c.a, p.lat); c.b = min(c.b, p.lon); c.c = max(c.c, p.lat); c.d = max(c.d, p.lon)
            cells[key] = c
        }
        let spots = cells.values.map { c in
            Spot(CLLocationCoordinate2D(latitude: c.lat / Double(c.ids.count), longitude: c.lon / Double(c.ids.count)), cover: c.cover, ids: c.ids, box: (c.a, c.b, c.c, c.d))
        }
        map.removeAnnotations(map.annotations.filter { $0 is Spot })  // the pins stay
        map.addAnnotations(spots)
    }

    /// A bubble tapped: one photo opens at once, more ask whether to open them all or zoom in.
    func choose(_ s: Spot) {
        choice = s
    }

    func zoom(to s: Spot) {
        let pad = 0.0005
        let box = (s.box.minLat - pad, s.box.minLon - pad, s.box.maxLat + pad, s.box.maxLon + pad)
        let span = MKCoordinateSpan(latitudeDelta: min(170, max(0.004, (box.2 - box.0) * 1.4)), longitudeDelta: min(360, max(0.004, (box.3 - box.1) * 1.4)))
        map?.setRegion(MKCoordinateRegion(center: s.coordinate, span: span), animated: true)
    }

    /// What is on screen as the bbox filter: "south,west,north,east".
    func visibleBox() -> String? {
        guard let r = map?.region else { return nil }
        let s = max(-90, r.center.latitude - r.span.latitudeDelta / 2), n = min(90, r.center.latitude + r.span.latitudeDelta / 2)
        let w = max(-180, r.center.longitude - r.span.longitudeDelta / 2), e = min(180, r.center.longitude + r.span.longitudeDelta / 2)
        return [s, w, n, e].map { String(format: "%.4f", $0) }.joined(separator: ",")
    }

    /// A place found: the map goes there, with a pin (which takes the selected photos while placing).
    func pin(at c: CLLocationCoordinate2D, title: String) {
        guard let map else { return }
        if let pin { map.removeAnnotation(pin) }
        let m = Mark()
        m.coordinate = c; m.title = title; m.takesPhotos = true
        pin = m
        map.addAnnotation(m)
        map.setRegion(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)), animated: true)
    }

    // MARK: Placing photos without a location

    func togglePlacing(_ query: PhotoQuery) async {
        placing.toggle()
        selected = []
        guard placing else { return }
        loadingTray = true
        defer { loadingTray = false }
        let q = query.setting("bbox", nil).setting("trail", nil).setting("ids", nil).setting("geo", "0")
        unplaced = Array(((try? await PhotoList.load(q.items))?.ids ?? []).prefix(600))
    }

    /// The map tapped while placing: the selected photos go there.
    func tapped(_ c: CLLocationCoordinate2D) {
        guard placing else { return }
        guard !selected.isEmpty else { toast = Toast(text: "Select photos in the tray first."); return }
        let picked = unplaced.filter { selected.contains($0) }
        Task { await place(picked, at: c) }
    }

    private func place(_ picked: [Int], at c: CLLocationCoordinate2D) async {
        let lat = (c.latitude * 1e7).rounded() / 1e7, lon = (c.longitude * 1e7).rounded() / 1e7
        do {
            try await EditAPI.edit(picked, ["gps": ["lat": lat, "lon": lon, "alt": NSNull()]])
        } catch { toast = Toast(text: error.localizedDescription); return }
        let gone = Set(picked)
        unplaced.removeAll { gone.contains($0) }
        selected = []
        points.append(contentsOf: picked.map { ($0, lat, lon) })
        count = points.count
        regroup()
        toast = Toast(text: "\(plural(picked.count, "photo")) placed.") { [weak self] in
            guard let self else { return }
            do { try await EditAPI.edit(picked, ["gps": NSNull()]) } catch { toast = Toast(text: error.localizedDescription); return }
            points.removeAll { gone.contains($0.id) }
            count = points.count
            unplaced.insert(contentsOf: picked, at: 0)
            regroup()
            toast = nil
        }
    }
}

// MARK: - Events

/// Days with many photos and trips away, newest first by year, as iopix finds them.
struct EventsScreen: View {
    struct Event: Identifiable {
        let kind: String, title: String, when: String, from: String, to: String, count: Int, days: Int, cover: Int?, places: [String]
        var id: String { from + to + title }
        var year: String { String(from.prefix(4)) }
    }
    @EnvironmentObject private var router: Router
    @State private var events: [Event]?
    @State private var problem: String?
    @State private var show = "all"
    @State private var find = ""

    /// The events that match the kind and the words typed, by year, newest first.
    private var years: [(String, [Event])] {
        let f = norm(find.trimmingCharacters(in: .whitespaces))
        var by: [String: [Event]] = [:]
        for e in events ?? [] where (show == "all" || e.kind == show) && (f.isEmpty || norm(e.title + " " + e.places.joined(separator: " ")).contains(f)) {
            by[e.year, default: []].append(e)
        }
        return by.sorted { $0.key > $1.key }
    }

    var body: some View {
        List {
            Section {
                TextField("Find an event or trip…", text: $find).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                Picker("Show", selection: $show) {
                    Text("All").tag("all"); Text("Trips").tag("trip"); Text("Events").tag("event")
                }
                .pickerStyle(.segmented)
            }
            if let events {
                ForEach(years, id: \.0) { year, list in
                    Section {
                        ForEach(list) { e in
                            Button { router.push(.photos(PhotoQuery([("from", e.from), ("to", e.to), ("sort", "old")]), title: e.title)) } label: {
                                ThumbRow(cover: e.cover, title: e.title,
                                         sub: "\(e.when) · \(e.count.formatted())\(e.kind == "trip" && e.days > 1 ? " · \(e.days) days" : "")",
                                         symbol: e.kind == "trip" ? "airplane" : "calendar")
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(year)
                            Text("\(list.count)").foregroundStyle(.secondary)
                            Spacer()
                            Button("All of \(year)") { router.push(.photos(PhotoQuery([("year", year)]), title: year)) }
                                .font(.footnote).textCase(nil)
                        }
                    }
                }
                if events.isEmpty { Text(problem.map { "Couldn't load the events. \($0)" } ?? "No events found yet.").foregroundStyle(.secondary) }
                else if years.isEmpty { Text("Nothing matches.").foregroundStyle(.secondary) }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Events & trips")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let j: [String: Any]
        do { j = try await IopixClient.shared.json("api/events") } catch { problem = error.localizedDescription; events = events ?? []; return }
        problem = nil
        events = (j["events"] as? [[String: Any]] ?? []).compactMap { e in
            guard let from = e["from"] as? String, let to = e["to"] as? String else { return nil }
            return Event(kind: e["kind"] as? String ?? "event", title: e["title"] as? String ?? from, when: e["when"] as? String ?? from,
                         from: from, to: to, count: (e["n"] as? NSNumber)?.intValue ?? 0, days: (e["days"] as? NSNumber)?.intValue ?? 1,
                         cover: (e["cover"] as? NSNumber)?.intValue, places: e["places"] as? [String] ?? [])
        }
    }
}
