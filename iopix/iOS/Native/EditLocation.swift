import SwiftUI
import MapKit

/// Setting where a photo was taken: search an address or place, take the position of a photo taken around the
/// same time, ask for a landmark (when the server has a Google key), or drop the pin on the map.
struct EditLocationSheet: View {
    let photo: Int
    let lat: Double?
    let lon: Double?
    let done: (Double, Double, Double?) -> Void

    struct Hit: Identifiable {
        let name: String, detail: String, lat: Double, lon: Double, alt: Double?, thumb: Int?
        var id: String { "\(name)|\(lat)|\(lon)" }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var pin: CLLocationCoordinate2D?
    @State private var alt: Double?
    @State private var camera: MapCameraPosition = .automatic
    @State private var search = ""
    @State private var hits: [Hit] = []
    @State private var suggestions: [Hit] = []
    @State private var landmarks = false
    @State private var note: String?
    @State private var looking = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapReader { proxy in
                    Map(position: $camera) {
                        if let pin { Marker("Here", coordinate: pin).tint(Hue.green) }
                    }
                    .onTapGesture { p in
                        if let c = proxy.convert(p, from: .local) { pin = c; alt = nil }
                    }
                }
                .frame(minHeight: 240)
                List {
                    if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                    if !hits.isEmpty {
                        Section("Found") { ForEach(hits) { row($0) } }
                    }
                    Section {
                        if suggestions.isEmpty {
                            Button { Task { await suggest() } } label: {
                                if looking { ProgressView() } else { Label("Suggest from photos taken around then", systemImage: "sparkles") }
                            }
                        } else {
                            ForEach(suggestions) { row($0) }
                        }
                        if landmarks {
                            Button { Task { await landmark() } } label: { Label("Recognise a landmark in the photo", systemImage: "building.columns") }
                        }
                    } header: { Text("Suggestions") } footer: { Text("Or tap the map to put the pin there.") }
                }
                .listStyle(.insetGrouped)
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search an address or place")
            .onSubmit(of: .search) { Task { await find() } }
            .navigationTitle("Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") { if let p = pin { done(p.latitude, p.longitude, alt) }; dismiss() }.disabled(pin == nil)
                }
            }
            .onAppear {
                if let lat, let lon {
                    let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    pin = c
                    camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 1500, longitudinalMeters: 1500))
                }
            }
        }
    }

    private func row(_ h: Hit) -> some View {
        Button {
            let c = CLLocationCoordinate2D(latitude: h.lat, longitude: h.lon)
            pin = c; alt = h.alt
            withAnimation { camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 1500, longitudinalMeters: 1500)) }
        } label: {
            HStack(spacing: 10) {
                if let t = h.thumb { RemoteImage(path: "thumb/\(t)").frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 6)) }
                else { Image(systemName: "mappin.circle.fill").foregroundStyle(Hue.green).font(.title3) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.name).foregroundStyle(.primary).lineLimit(1)
                    if !h.detail.isEmpty { Text(h.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        }
    }

    private func find() async {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        note = nil
        do {
            let r = try await EditAPI.get("api/geocode", [URLQueryItem(name: "q", value: q)])
            hits = (r["results"] as? [[String: Any]] ?? []).compactMap { x in
                guard let la = (x["lat"] as? NSNumber)?.doubleValue, let lo = (x["lon"] as? NSNumber)?.doubleValue else { return nil }
                return Hit(name: x["name"] as? String ?? q, detail: x["detail"] as? String ?? "", lat: la, lon: lo, alt: nil, thumb: nil)
            }
            if hits.isEmpty { note = r["source"] as? String == "offline" ? "No town by that name in the offline list." : "Nothing found." }
            if let n = r["note"] as? String { note = n }
        } catch {
            note = error.localizedDescription
        }
    }

    private func suggest() async {
        looking = true
        defer { looking = false }
        do {
            let r = try await EditAPI.get("api/location/suggest", [URLQueryItem(name: "id", value: "\(photo)")])
            landmarks = r["landmarks"] as? Bool ?? false
            suggestions = (r["suggestions"] as? [[String: Any]] ?? []).compactMap { x in
                guard let la = (x["lat"] as? NSNumber)?.doubleValue, let lo = (x["lon"] as? NSNumber)?.doubleValue else { return nil }
                let m = (x["minutes"] as? NSNumber)?.intValue ?? 0
                let when = m == 0 ? "same time" : abs(m) < 60 ? "\(abs(m)) min \(m < 0 ? "before" : "after")" : "\(abs(m) / 60) h \(m < 0 ? "before" : "after")"
                let place = (x["place"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(format: "%.4f, %.4f", la, lo)
                let other = (x["same_camera"] as? Bool ?? true) ? "" : " (another camera)"
                return Hit(name: place, detail: "\(x["name"] as? String ?? ""), taken \(when)\(other)", lat: la, lon: lo,
                           alt: (x["alt"] as? NSNumber)?.doubleValue, thumb: (x["id"] as? NSNumber)?.intValue)
            }
            if suggestions.isEmpty { note = "No photo with a location was taken within 6 hours of this one." }
        } catch {
            note = error.localizedDescription
        }
    }

    private func landmark() async {
        note = "Asking Google Cloud Vision…"
        do {
            let r = try await EditAPI.post("api/location/landmark", ["id": photo])
            let found = (r["landmarks"] as? [[String: Any]] ?? []).compactMap { x -> Hit? in
                guard let la = (x["lat"] as? NSNumber)?.doubleValue, let lo = (x["lon"] as? NSNumber)?.doubleValue else { return nil }
                let score = Int((((x["score"] as? NSNumber)?.doubleValue) ?? 0) * 100)
                return Hit(name: x["name"] as? String ?? "Landmark", detail: "landmark, \(score)% sure", lat: la, lon: lo, alt: nil, thumb: nil)
            }
            hits = found + hits
            note = found.isEmpty ? "No landmark recognised in this photo." : nil
        } catch {
            note = error.localizedDescription
        }
    }
}
