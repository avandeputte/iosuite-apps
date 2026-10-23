import SwiftUI
import MapKit

struct EventItem: Identifiable, Hashable {
    let title: String
    let from: String
    let to: String
    let when: String
    let count: Int
    let cover: Int?
    var id: String { from + to + title }
}

struct ThenAndNow: Identifiable {
    let name: String
    let then: Int
    let now: Int
    let years: Double
    var id: String { name }
}

/// A row of photos that scrolls sideways; picking one opens the viewer on that row.
struct PhotoRow: View {
    let title: String
    let list: PhotoList
    var more: AnyView? = nil
    @State private var viewer: ViewerStart?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 30) {
                Text(title).font(.title3.bold())
                Button { viewer = ViewerStart(list: list, index: 0, playing: true) } label: { Image(systemName: "play.fill") }
                if let more { more }
            }
            .padding(.horizontal, 60)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 30) {
                    ForEach(Array(list.ids.prefix(40).enumerated()), id: \.offset) { i, id in
                        Button { viewer = ViewerStart(list: list, index: i, playing: false) } label: {
                            RemoteImage(path: "thumb/\(id)").frame(width: 360, height: 240)
                                .overlay(alignment: .bottomLeading) {
                                    if list.isVideo(i) { Image(systemName: "play.circle.fill").font(.title2).padding(10) }
                                }
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 60).padding(.vertical, 30)
            }
        }
        .fullScreenCover(item: $viewer) { PhotoViewer(start: $0) }
    }
}

/// The first page: On this day, Then and now, Events and trips, Rediscover.
struct ForYouView: View {
    @State private var today: PhotoList?
    @State private var random = PhotoList()
    @State private var events: [EventItem] = []
    @State private var pairs: [ThenAndNow] = []
    @State private var viewer: ViewerStart?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if let today, !today.ids.isEmpty {
                    PhotoRow(title: "On this day · \(Date().formatted(.dateTime.month(.wide).day()))", list: today,
                             more: AnyView(NavigationLink("See all by year") { OnThisDayView() }))
                }
                if !pairs.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Then and now").font(.title3.bold()).padding(.horizontal, 60)
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 40) {
                                ForEach(pairs) { p in
                                    Button { viewer = ViewerStart(list: PhotoList(ids: [p.then, p.now]), index: 0, playing: false) } label: {
                                        VStack(spacing: 12) {
                                            HStack(spacing: 6) {
                                                RemoteImage(path: "thumb/\(p.then)").frame(width: 250, height: 250)
                                                RemoteImage(path: "thumb/\(p.now)").frame(width: 250, height: 250)
                                            }
                                            Text(p.name).font(.headline)
                                            Text("\(Int(p.years.rounded())) years apart").font(.caption).foregroundStyle(.secondary)
                                        }
                                        .padding(.bottom, 16)
                                    }
                                    .buttonStyle(.card)
                                }
                            }
                            .padding(.horizontal, 60).padding(.vertical, 30)
                        }
                    }
                }
                if !events.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Events and trips").font(.title3.bold()).padding(.horizontal, 60)
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 48) {
                                ForEach(events) { e in
                                    NavigationLink(value: e) {
                                        CoverCard(title: e.title, subtitle: "\(e.when) · \(e.count)", image: e.cover.map { "thumb/\($0)" })
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(.horizontal, 60).padding(.vertical, 30)
                        }
                    }
                }
                if !random.ids.isEmpty {
                    PhotoRow(title: "Rediscover", list: random,
                             more: AnyView(Button { Task { await shuffle() } } label: { Label("Shuffle", systemImage: "shuffle") }))
                }
            }
            .padding(.vertical, 30)
        }
        .navigationDestination(for: EventItem.self) { e in
            ScrollView { PhotoGrid(query: [URLQueryItem(name: "from", value: e.from), URLQueryItem(name: "to", value: e.to)]) }
                .navigationTitle(e.title)
        }
        .fullScreenCover(item: $viewer) { PhotoViewer(start: $0) }
        .task { await load() }
    }

    private func load() async {
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        today = (try? await PhotoList.load([URLQueryItem(name: "md", value: String(format: "%02d-%02d", c.month ?? 1, c.day ?? 1))])) ?? PhotoList()
        if random.ids.isEmpty { await shuffle() }
        if let j = try? await IopixClient.shared.json("api/thenandnow", query: [URLQueryItem(name: "n", value: "8")]) {
            pairs = (j["pairs"] as? [[String: Any]] ?? []).compactMap { p in
                guard let name = p["name"] as? String,
                      let a = ((p["then"] as? [String: Any])?["photo"] as? NSNumber)?.intValue,
                      let b = ((p["now"] as? [String: Any])?["photo"] as? NSNumber)?.intValue else { return nil }
                return ThenAndNow(name: name, then: a, now: b, years: (p["years"] as? NSNumber)?.doubleValue ?? 0)
            }
        }
        if let j = try? await IopixClient.shared.json("api/events") {
            events = (j["events"] as? [[String: Any]] ?? []).prefix(30).compactMap { e in
                guard let from = e["from"] as? String, let to = e["to"] as? String else { return nil }
                return EventItem(title: e["title"] as? String ?? from, from: from, to: to, when: e["when"] as? String ?? from,
                                 count: (e["n"] as? NSNumber)?.intValue ?? 0, cover: (e["cover"] as? NSNumber)?.intValue)
            }
        }
    }

    private func shuffle() async {
        guard let j = try? await IopixClient.shared.json("api/random", query: [URLQueryItem(name: "n", value: "40")]) else { return }
        random = PhotoList(ids: (j["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue })
    }
}

/// Where photos were taken: a map, then places by country (or, when iopix has no place names yet, areas on the map).
struct PlacesView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var spots: [Spot] = []

    struct Spot: Identifiable, Hashable {
        let lat: Double, lon: Double, count: Int, cover: Int
        var id: String { "\(lat),\(lon)" }
        var bbox: String { "\(lat - 0.25),\(lon - 0.25),\(lat + 0.25),\(lon + 0.25)" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if !spots.isEmpty {
                    Map(initialPosition: .automatic, interactionModes: []) {
                        ForEach(spots.prefix(300)) { s in
                            Annotation("", coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)) {
                                Text("\(s.count)").font(.caption2.bold()).padding(8).background(.pink, in: Circle()).foregroundStyle(.white)
                            }
                        }
                    }
                    .frame(height: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .padding(.horizontal, 60)
                    .focusable(false)
                }
                if !store.places.isEmpty {
                    ForEach(countries, id: \.self) { country in
                        VStack(alignment: .leading, spacing: 16) {
                            Text(country.isEmpty ? "Elsewhere" : country).font(.title3.bold()).padding(.horizontal, 60)
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 48) {
                                    ForEach(store.places.filter { ($0.country ?? "") == country }.prefix(40)) { p in
                                        NavigationLink(value: p) {
                                            CoverCard(title: p.name, subtitle: [p.region, "\(p.count)"].compactMap { $0 }.joined(separator: " · "),
                                                      image: p.cover.map { "thumb/\($0)" })
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                                .padding(.horizontal, 60).padding(.vertical, 30)
                            }
                        }
                    }
                } else if !spots.isEmpty {
                    Text("Areas").font(.title3.bold()).padding(.horizontal, 60)
                    LazyVGrid(columns: gridColumns, spacing: 60) {
                        ForEach(spots.prefix(40)) { s in
                            NavigationLink(value: s) {
                                CoverCard(title: String(format: "Around %.2f, %.2f", s.lat, s.lon), subtitle: "\(s.count)", image: "thumb/\(s.cover)")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal, 60)
                } else {
                    Text("No photos with a location yet.").foregroundStyle(.secondary).padding(80)
                }
            }
            .padding(.vertical, 30)
        }
        .navigationTitle("Places")
        .navigationDestination(for: Place.self) { p in
            ScrollView {
                PhotoGrid(query: [URLQueryItem(name: "place", value: p.name)] + (p.country.map { [URLQueryItem(name: "country", value: $0)] } ?? []))
            }
            .navigationTitle(p.name)
        }
        .navigationDestination(for: Spot.self) { s in
            ScrollView { PhotoGrid(query: [URLQueryItem(name: "bbox", value: s.bbox)]) }
                .navigationTitle(String(format: "Around %.2f, %.2f", s.lat, s.lon))
        }
        .task { await loadSpots() }
    }

    private var countries: [String] {
        var seen: [String: Int] = [:]
        for p in store.places { seen[p.country ?? "", default: 0] += p.count }
        return seen.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Photos with a position, gathered into half-degree squares.
    private func loadSpots() async {
        guard spots.isEmpty, let j = try? await IopixClient.shared.json("api/map") else { return }
        let ids = (j["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        let lats = (j["lat"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        let lons = (j["lon"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        var cells: [String: (lat: Double, lon: Double, n: Int, cover: Int)] = [:]
        for i in 0..<min(ids.count, lats.count, lons.count) {
            let key = "\(Int((lats[i] * 2).rounded())),\(Int((lons[i] * 2).rounded()))"
            if var c = cells[key] { c.n += 1; cells[key] = c } else { cells[key] = (lats[i], lons[i], 1, ids[i]) }
        }
        spots = cells.values.map { Spot(lat: $0.lat, lon: $0.lon, count: $0.n, cover: $0.cover) }.sorted { $0.count > $1.count }
    }
}
