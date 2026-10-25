import SwiftUI
import MapKit

// MARK: - Places

/// Where photos were taken: a map with photos gathered as you zoom out, or the places by country.
struct PlacesScreen: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var router: Router

    var body: some View {
        Group {
            if router.placesShowsMap {
                PhotoMap { bbox in router.placesPath.append(.photos(PhotoQuery([("bbox", bbox)]), title: "This area")) }
                    .ignoresSafeArea(edges: .bottom)
            } else {
                placeList
            }
        }
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $router.placesShowsMap) {
                    Text("Map").tag(true); Text("Places").tag(false)
                }
                .pickerStyle(.segmented).frame(width: 200)
            }
        }
    }

    private var countries: [(String, [Place])] {
        var by: [String: [Place]] = [:]
        for p in store.places { by[p.country ?? "", default: []].append(p) }
        return by.map { ($0.key, $0.value.sorted { $0.count > $1.count }) }
            .sorted { $0.1.reduce(0) { $0 + $1.count } > $1.1.reduce(0) { $0 + $1.count } }
    }

    private var placeList: some View {
        List {
            if store.places.isEmpty {
                Text("No place names yet. iopix names places from the photos' locations.").foregroundStyle(.secondary)
            }
            ForEach(countries, id: \.0) { country, places in
                Section(country.isEmpty ? "Elsewhere" : country) {
                    ForEach(places) { p in
                        Button {
                            var q: [(String, String)] = [("place", p.name)]
                            if let r = p.region { q.append(("region", r)) }
                            if let c = p.country { q.append(("country", c)) }
                            router.placesPath.append(.photos(PhotoQuery(q), title: p.name))
                        } label: {
                            ThumbRow(cover: p.cover, title: p.name, sub: [p.region, p.count.formatted()].compactMap { $0 }.joined(separator: " · "))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
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
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// Every photo with a location on a map, gathered into bubbles that split as you zoom in. Tap a bubble to zoom to
/// it; once it is small enough, tapping opens its photos.
struct PhotoMap: UIViewRepresentable {
    let open: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(open) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.register(Bubble.self, forAnnotationViewWithReuseIdentifier: "bubble")
        context.coordinator.map = map
        Task { await context.coordinator.load() }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {}

    final class Spot: NSObject, MKAnnotation {
        let coordinate: CLLocationCoordinate2D
        let count: Int, cover: Int
        let box: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)
        init(_ c: CLLocationCoordinate2D, count: Int, cover: Int, box: (Double, Double, Double, Double)) {
            coordinate = c; self.count = count; self.cover = cover; self.box = box
        }
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

        func show(_ s: Spot) {
            label.text = s.count > 999 ? "\(s.count / 1000)k" : "\(s.count)"
            label.sizeToFit()
            let w = max(18, label.bounds.width + 10)
            label.frame = CGRect(x: bounds.width - w + 6, y: -6, width: w, height: 18)
            photo.image = ImageCache.shared.cached("thumb/\(s.cover)")
            if photo.image == nil {
                let id = s.cover
                Task { @MainActor in
                    let img = await ImageCache.shared.image("thumb/\(id)")
                    if (self.annotation as? Spot)?.cover == id { self.photo.image = img }
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var map: MKMapView?
        let open: (String) -> Void
        private var points: [(id: Int, lat: Double, lon: Double)] = []

        init(_ open: @escaping (String) -> Void) { self.open = open }

        func load() async {
            guard let j = try? await IopixClient.shared.json("api/map") else { return }
            let ids = j["id"] as? [Any] ?? [], lats = j["lat"] as? [Any] ?? [], lons = j["lon"] as? [Any] ?? []
            var pts: [(Int, Double, Double)] = []
            for i in 0..<min(ids.count, lats.count, lons.count) {
                guard let id = (ids[i] as? NSNumber)?.intValue, let la = (lats[i] as? NSNumber)?.doubleValue,
                      let lo = (lons[i] as? NSNumber)?.doubleValue else { continue }
                pts.append((id, la, lo))
            }
            points = pts
            guard let map, !pts.isEmpty else { return }
            // start on where most photos are: the middle 90% of them
            let la = pts.map(\.1).sorted(), lo = pts.map(\.2).sorted()
            let a = Int(Double(pts.count) * 0.05), b = max(a, Int(Double(pts.count) * 0.95) - 1)
            // never wider than the world: MapKit throws on a span past 180° of latitude or 360° of longitude
            let span = MKCoordinateSpan(latitudeDelta: min(170, max(0.05, (la[b] - la[a]) * 1.3)), longitudeDelta: min(360, max(0.05, (lo[b] - lo[a]) * 1.3)))
            map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (la[a] + la[b]) / 2, longitude: (lo[a] + lo[b]) / 2), span: span), animated: false)
            regroup()
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) { regroup() }

        /// Bubbles of about 84 points across for what is on screen (a bubble is 52 wide, so they rarely overlap).
        private func regroup() {
            guard let map, map.bounds.width > 0, map.bounds.height > 0 else { return }
            let r = map.region
            let cellLat = r.span.latitudeDelta * 84 / Double(map.bounds.height)
            let cellLon = r.span.longitudeDelta * 84 / Double(map.bounds.width)
            guard cellLat > 0, cellLon > 0, cellLat.isFinite, cellLon.isFinite else { return }  // a span of nothing: no cells to put photos in
            let minLat = r.center.latitude - r.span.latitudeDelta, maxLat = r.center.latitude + r.span.latitudeDelta
            let minLon = r.center.longitude - r.span.longitudeDelta, maxLon = r.center.longitude + r.span.longitudeDelta
            // a view across the date line (or most of the world) takes every longitude: a plain range would miss the far side
            let allLon = minLon < -180 || maxLon > 180
            struct Cell { var n = 0, cover = 0, lat = 0.0, lon = 0.0, a = 90.0, b = 180.0, c = -90.0, d = -180.0 }
            struct Key: Hashable { let row: Int, col: Int }  // two numbers, not one made of both: no two cells share a key
            var cells: [Key: Cell] = [:]
            for p in points where p.lat >= minLat && p.lat <= maxLat && (allLon || (p.lon >= minLon && p.lon <= maxLon)) {
                let key = Key(row: Int((p.lat / cellLat).rounded(.down)), col: Int((p.lon / cellLon).rounded(.down)))
                var c = cells[key] ?? Cell(cover: p.id)
                c.n += 1; c.lat += p.lat; c.lon += p.lon
                c.a = min(c.a, p.lat); c.b = min(c.b, p.lon); c.c = max(c.c, p.lat); c.d = max(c.d, p.lon)
                cells[key] = c
            }
            let spots = cells.values.map { c in
                Spot(CLLocationCoordinate2D(latitude: c.lat / Double(c.n), longitude: c.lon / Double(c.n)), count: c.n, cover: c.cover, box: (c.a, c.b, c.c, c.d))
            }
            map.removeAnnotations(map.annotations)
            map.addAnnotations(spots)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let s = annotation as? Spot else { return nil }
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: "bubble", for: s) as? Bubble
            v?.annotation = s
            v?.show(s)
            return v
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            mapView.deselectAnnotation(annotation, animated: false)
            guard let s = annotation as? Spot else { return }
            let pad = 0.0005
            let box = (s.box.minLat - pad, s.box.minLon - pad, s.box.maxLat + pad, s.box.maxLon + pad)
            if s.count <= 30 || mapView.region.span.latitudeDelta < 0.02 || (box.2 - box.0 < 0.002 && box.3 - box.1 < 0.002) {
                open("\(box.0),\(box.1),\(box.2),\(box.3)")
            } else {
                let span = MKCoordinateSpan(latitudeDelta: min(170, max(0.004, (box.2 - box.0) * 1.4)), longitudeDelta: min(360, max(0.004, (box.3 - box.1) * 1.4)))
                mapView.setRegion(MKCoordinateRegion(center: s.coordinate, span: span), animated: true)
            }
        }
    }
}

// MARK: - Events

/// Days with many photos and trips away, newest first, as iopix finds them.
struct EventsScreen: View {
    struct Event: Identifiable {
        let kind: String, title: String, when: String, from: String, to: String, count: Int, days: Int, cover: Int?
        var id: String { from + to + title }
    }
    @EnvironmentObject private var router: Router
    @State private var events: [Event]?
    @State private var problem: String?
    @State private var show = "all"

    var body: some View {
        List {
            Picker("Show", selection: $show) {
                Text("All").tag("all"); Text("Trips").tag("trip"); Text("Events").tag("event")
            }
            .pickerStyle(.segmented)
            if let events {
                ForEach(events.filter { show == "all" || $0.kind == show }) { e in
                    Button { router.morePath.append(.photos(PhotoQuery([("from", e.from), ("to", e.to), ("sort", "old")]), title: e.title)) } label: {
                        ThumbRow(cover: e.cover, title: e.title,
                                 sub: "\(e.when) · \(e.count.formatted())\(e.days > 1 ? " · \(e.days) days" : "")",
                                 symbol: e.kind == "trip" ? "airplane" : "calendar")
                    }
                    .buttonStyle(.plain)
                }
                if events.isEmpty { Text(problem.map { "Couldn't load the events. \($0)" } ?? "No events found yet.").foregroundStyle(.secondary) }
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
                         cover: (e["cover"] as? NSNumber)?.intValue)
        }
    }
}
