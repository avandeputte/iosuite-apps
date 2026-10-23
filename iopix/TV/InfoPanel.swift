import SwiftUI

/// What iopix knows about a photo, for the panel beside it.
struct PhotoInfo {
    var title: String?
    var when: String?
    var place: String?
    var people: [String] = []
    var tags: [String] = []
    var folder: String?
    var camera: String?
    var settings: String?
    var file: String?
    var rating = 0

    static func load(_ id: Int) async -> PhotoInfo? {
        guard let d = try? await IopixClient.shared.json("api/photo/\(id)") else { return nil }
        func str(_ k: String) -> String? { (d[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        var i = PhotoInfo()
        i.title = str("title") ?? str("caption") ?? str("caption_ai")
        if let taken = str("taken") {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            if let date = f.date(from: taken) {
                i.when = date.formatted(date: .complete, time: .shortened)
            } else { i.when = taken }
        }
        let place = [str("place"), str("region"), str("country")].compactMap { $0 }
        if !place.isEmpty {
            i.place = place.joined(separator: ", ")
        } else if let lat = num("lat"), let lon = num("lon") {
            i.place = String(format: "%.4f, %.4f", lat, lon)
        }
        let tags = d["tags"] as? [[String: Any]] ?? []
        i.people = tags.filter { ($0["person"] as? NSNumber)?.boolValue == true }.compactMap { $0["name"] as? String }
        i.tags = tags.filter { ($0["person"] as? NSNumber)?.boolValue != true }.compactMap { $0["name"] as? String }
        i.folder = (d["album"] as? [String: Any])?["path"] as? String
        i.camera = [str("camera"), str("lens")].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
        var s: [String] = []
        if let a = num("aperture"), a > 0 { s.append(String(format: "f/%.1f", a)) }
        if let e = num("exposure"), e > 0 { s.append(e >= 1 ? String(format: "%.1f s", e) : "1/\(Int((1 / e).rounded())) s") }
        if let iso = num("iso"), iso > 0 { s.append("ISO \(Int(iso))") }
        if let f = num("focal35") ?? num("focal"), f > 0 { s.append("\(Int(f.rounded())) mm") }
        i.settings = s.isEmpty ? nil : s.joined(separator: " · ")
        var file: [String] = []
        if let w = num("w"), let h = num("h"), w > 0 { file.append("\(Int(w)) × \(Int(h))") }
        if let size = num("size") { file.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let fmt = str("fmt") { file.append(fmt) }
        if let dur = num("duration"), dur > 0 { file.append("\(Int(dur) / 60):" + String(format: "%02d", Int(dur) % 60)) }
        i.file = ([str("name")].compactMap { $0 } + [file.joined(separator: " · ")]).filter { !$0.isEmpty }.joined(separator: "\n")
        i.rating = Int(num("rating") ?? 0)
        return i
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct InfoPanel: View {
    let photo: Int
    @State private var info: PhotoInfo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if let info {
                    if let t = info.title { Text(t).font(.title3.bold()) }
                    if info.rating > 0 { Text(String(repeating: "★", count: min(info.rating, 5))).foregroundStyle(.yellow) }
                    row("calendar", info.when)
                    row("mappin.and.ellipse", info.place)
                    row("person.2.fill", info.people.isEmpty ? nil : info.people.joined(separator: ", "))
                    row("tag.fill", info.tags.isEmpty ? nil : info.tags.joined(separator: ", "))
                    row("folder.fill", info.folder)
                    row("camera.fill", info.camera)
                    row("camera.aperture", info.settings)
                    row("doc.fill", info.file)
                } else {
                    ProgressView()
                }
            }
            .padding(50)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 640)
        .background(.ultraThinMaterial)
        .task(id: photo) {
            info = nil
            info = await PhotoInfo.load(photo)
        }
    }

    @ViewBuilder private func row(_ icon: String, _ text: String?) -> some View {
        if let text {
            HStack(alignment: .top, spacing: 20) {
                Image(systemName: icon).frame(width: 40).foregroundStyle(.secondary)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
