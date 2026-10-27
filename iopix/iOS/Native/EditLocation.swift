import SwiftUI
import MapKit

/// Setting where a photo was taken: search an address or place, take the position of a photo taken around the
/// same time, ask for a landmark (when the server has a Google key), or drop the pin on the map.
struct EditLocationSheet: View {
    let photo: Int
    let lat: Double?
    let lon: Double?
    var accuracy: Double? = nil
    /// latitude, longitude, altitude, and how far off it may be (metres) when only the town is known
    let done: (Double, Double, Double?, Double?) -> Void

    /// How far off an approximate position may be, as the web app offers it: round numbers in the units of the
    /// region (miles in the US), in metres.
    static var accuracyChoices: [Double] {
        let mile = 1609.344
        return [1, 2, 5, 10, 25].map { Locale.current.measurementSystem == .us ? ($0 * mile).rounded() : $0 * 1000 }
    }

    static func distance(_ m: Double) -> String {
        Measurement(value: m, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

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
    @State private var townOnly = false
    @State private var radius = EditLocationSheet.accuracyChoices[1]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapReader { proxy in
                    Map(position: $camera) {
                        if let pin {
                            if townOnly {
                                MapCircle(center: pin, radius: radius).foregroundStyle(.orange.opacity(0.15)).stroke(.orange, lineWidth: 1)
                            }
                            Marker("Here", coordinate: pin).tint(townOnly ? .orange : Hue.green)
                        }
                    }
                    .onTapGesture { p in
                        if let c = proxy.convert(p, from: .local) { pin = c; alt = nil }
                    }
                }
                .frame(height: mapHeight)  // a fixed share: the found places and suggestions below need room too
                List {
                    Section {
                        Toggle("Only the town is known", isOn: $townOnly)
                        if townOnly {
                            Picker("Within about", selection: $radius) {
                                ForEach(Self.accuracyChoices, id: \.self) { Text(Self.distance($0)).tag($0) }
                            }
                        }
                    } footer: {
                        if townOnly { Text("Find the town and put the pin on its center. The photo is saved as approximate, without altitude.") }
                    }
                    if !hits.isEmpty {
                        Section("Found") { ForEach(hits) { row($0) } }
                    }
                    Section {
                        // what came of a search or a suggestion shows here, where the eye is
                        if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
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
            .onChange(of: townOnly) { _, _ in fitCircle() }
            .onChange(of: radius) { _, _ in fitCircle() }
            .navigationTitle("Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if let p = pin { done(p.latitude, p.longitude, townOnly ? nil : alt, townOnly ? radius : nil) }
                        dismiss()
                    } label: { BarText("Use") }.disabled(pin == nil)
                }
            }
            .onAppear {
                Task { await suggest() }  // the likely places, from photos taken around then, are offered at once
                if let accuracy {
                    townOnly = true
                    radius = Self.accuracyChoices.min { abs($0 - accuracy) < abs($1 - accuracy) } ?? accuracy
                }
                if let lat, let lon {
                    let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    pin = c
                    camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 1500, longitudinalMeters: 1500))
                }
            }
        }
    }

    /// The whole of an approximate position's circle in view.
    private func fitCircle() {
        guard townOnly, let pin else { return }
        withAnimation { camera = .region(MKCoordinateRegion(center: pin, latitudinalMeters: radius * 2.6, longitudinalMeters: radius * 2.6)) }
    }

    @Environment(\.horizontalSizeClass) private var width
    private var mapHeight: CGFloat { width == .regular ? 320 : 260 }

    private func row(_ h: Hit) -> some View {
        Button {
            let c = CLLocationCoordinate2D(latitude: h.lat, longitude: h.lon)
            pin = c; alt = h.alt
            let span = townOnly ? radius * 2.6 : 1500
            withAnimation { camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: span, longitudinalMeters: span)) }
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
            hits = try await AppleSearch.places(q).map { Hit(name: $0.name, detail: $0.detail, lat: $0.lat, lon: $0.lon, alt: nil, thumb: nil) }
            if hits.isEmpty { note = "Nothing found." }
        } catch {
            hits = []
            note = AppleSearch.message(error)
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

extension View {
    /// On iPad and Mac a sheet opened from another sheet comes out small; this one asks for a page-sized sheet.
    @ViewBuilder func roomySheet() -> some View {
        if #available(iOS 18.0, *) { presentationSizing(.page) } else { self }
    }
}
