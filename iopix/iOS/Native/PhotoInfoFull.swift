import MapKit
import SwiftUI

/// Everything the web app's info panel shows about a photo, read from /api/photo/<id>.
struct PhotoDetail {
    struct Face: Identifiable {
        let id = UUID()
        enum Kind { case confirmed, suggested, unknown, tagOnly }
        let kind: Kind
        let tag: Int?
        let name: String?
        let rect: [Int]  // x, y, w, h; empty for a person tag without a face box
    }

    struct Version { let id: Int; let original: Bool }

    var id = 0
    var title: String?, caption: String?
    var date: Date?
    /// How much of the date is known: nil exact, 1 month and year, 2 year only, 3 unknown (iopix 1.80).
    var precision: Int?
    var day: String?
    var name = "", path = ""
    var w = 0, h = 0, size = 0
    var fmt: String?
    var video = false
    var folder: (id: Int, path: String)?
    var versions: [Version] = []
    var rating = 0
    var faces: [Face] = []
    var tags: [(id: Int, name: String)] = []
    var place: String?, region: String?, country: String?
    var lat: Double?, lon: Double?, alt: Double?
    var accuracy: Double?, facing: Double?
    var details: [(String, String)] = []
    var creator: String?
    var camera: String?, lens: String?, exposure: String?
    // AI analysis
    var captionAI: String?
    var concepts: [(name: String, p: Double)] = []
    var objects: [(name: String, n: Int)] = []
    var ocr: String?
    var sharpness: Double?, faceQuality: Double?, dark = false, bright = false
    /// Photo quality (iopix 1.81): ranks in the library (0...1), the aesthetic score (about 1-10), closed eyes, and
    /// why it looks like a reject. Suggestions only: nothing is marked until someone marks it.
    struct Quality { var focusRank: Double?, aestheticRank: Double?, aesthetic: Double?, eyesChecked = 0, eyesClosed = 0, rejectLabels: [String] = [] }
    var quality: Quality?
    var focusMeasured = false
    var pick = 0
    var burst: (id: Int, size: Int, best: Bool)?
    var similar = false

    var hasAI: Bool {
        captionAI != nil || !concepts.isEmpty || !objects.isEmpty || ocr != nil || sharpness != nil || quality != nil || burst != nil || (similar && !video)
    }

    static func load(_ id: Int) async -> PhotoDetail? {
        guard let d = try? await IopixClient.shared.json("api/photo/\(id)") else { return nil }
        func str(_ v: Any?) -> String? { (v as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        var p = PhotoDetail()
        p.id = id
        p.title = str(d["title"]); p.caption = str(d["caption"])
        if let ts = num(d["ts"]) { p.date = Date(timeIntervalSince1970: ts) }
        p.precision = PhotoDates.level(str(d["datePrecision"]))
        p.day = str(d["day"])
        p.name = str(d["name"]) ?? ""; p.path = str(d["path"]) ?? ""
        p.w = int(d["w"]) ?? 0; p.h = int(d["h"]) ?? 0; p.size = int(d["size"]) ?? 0
        p.fmt = str(d["fmt"])
        p.video = (int(d["video"]) ?? 0) != 0
        if let a = d["album"] as? [String: Any], let aid = int(a["id"]) {
            let path = (str(a["path"]) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            p.folder = (aid, path.isEmpty ? (str(a["name"]) ?? "") : path)
        }
        p.versions = (d["versions"] as? [[String: Any]] ?? []).compactMap { v in
            int(v["id"]).map { Version(id: $0, original: (v["role"] as? String) == "original") }
        }
        p.rating = max(0, int(d["rating"]) ?? 0)
        let allTags = d["tags"] as? [[String: Any]] ?? []
        var faced = Set<Int>()
        for f in d["faces"] as? [[String: Any]] ?? [] {
            let tag = int(f["tag"])
            if let tag { faced.insert(tag) }
            p.faces.append(Face(kind: .confirmed, tag: tag, name: str(f["name"]), rect: ["x", "y", "w", "h"].compactMap { int(f[$0]) }))
        }
        for f in d["faces_other"] as? [[String: Any]] ?? [] {
            let kind = f["kind"] as? String
            guard kind != "ignored" else { continue }
            p.faces.append(Face(kind: kind == "suggested" ? .suggested : .unknown, tag: int(f["tag"]), name: str(f["name"]),
                                rect: ["x", "y", "w", "h"].compactMap { int(f[$0]) }))
        }
        for t in allTags where (int(t["person"]) ?? 0) != 0 {
            if let tid = int(t["id"]), !faced.contains(tid) { p.faces.append(Face(kind: .tagOnly, tag: tid, name: str(t["name"]), rect: [])) }
        }
        // the "Date approximate" tag is said by the date row already
        p.tags = allTags.filter { (int($0["person"]) ?? 0) == 0 && !((str($0["full"]) ?? "").hasPrefix("Date approximate")) }.compactMap { t in
            guard let tid = int(t["id"]), let n = str(t["name"]) else { return nil }
            return (tid, n)
        }
        p.place = str(d["place"]); p.region = str(d["region"]); p.country = str(d["country"])
        p.lat = num(d["lat"]); p.lon = num(d["lon"]); p.alt = num(d["alt"])
        let ex = d["extra"] as? [String: Any] ?? [:]
        p.accuracy = num(ex["gpsAccuracy"]); p.facing = num(ex["orientationGps"])

        // Details, as the web app lists them
        var kv: [(String, String)] = []
        func add(_ k: String, _ v: String?) { if let v, !v.isEmpty { kv.append((k, v)) } }
        p.creator = str(d["creator"])
        add("Copyright", str(d["copyright"]))
        for (k, v) in (ex["copyright"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) where !["creator", "copyrightNotice"].contains(k) {
            let label = k.replacingOccurrences(of: "creatorContactInfo.", with: "")
                .replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression).lowercased()
            add(label.prefix(1).uppercased() + label.dropFirst(), str(v) ?? (v as? NSNumber)?.stringValue)
        }
        for (k, v) in (ex["properties"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) { add(k, str(v) ?? (v as? NSNumber)?.stringValue) }
        if p.video {
            let vid = ex["video"] as? [String: Any] ?? [:]
            if let dur = num(d["duration"]), dur > 0 { add("Duration", Self.duration(dur)) }
            add("Video codec", str(vid["codec"]))
            if let fps = num(vid["fps"]) ?? Double(str(vid["fps"]) ?? "") { add("Frame rate", "\(Self.trim(fps, 2)) fps") }
            add("Audio", str(vid["audio"]))
        }
        add("File modified", str(d["modified"])?.replacingOccurrences(of: "T", with: " "))
        p.details = kv

        p.camera = str(d["camera"]); p.lens = str(d["lens"])
        var e: [String] = []
        if let a = num(d["aperture"]), a > 0 { e.append("ƒ/\(Self.trim(a, 1))") }
        if let x = num(d["exposure"]), x > 0 { e.append(x < 1 ? "1/\(Int((1 / x).rounded())) s" : "\(Self.trim(x, 1)) s") }
        if let f = num(d["focal"]), f > 0 {
            let eq = num(d["focal35"]).flatMap { Int($0.rounded()) != Int(f.rounded()) ? " (\(Int($0.rounded())) mm eq.)" : nil } ?? ""
            e.append("\(Self.trim(f, 1)) mm\(eq)")
        }
        if let iso = int(d["iso"]), iso > 0 { e.append("ISO \(iso)") }
        if let flash = int(d["flash"]), flash & 1 == 1 { e.append("Flash") }
        p.exposure = e.isEmpty ? nil : e.joined(separator: " · ")

        // what a model produced
        if let c = str(d["caption_ai"]) { p.captionAI = c.prefix(1).uppercased() + c.dropFirst() }
        p.concepts = (d["concepts"] as? [[String: Any]] ?? []).compactMap { c in str(c["name"]).map { ($0, num(c["p"]) ?? 0) } }
        var counts: [String: Int] = [:], order: [String] = []
        for b in d["boxes"] as? [[String: Any]] ?? [] {
            guard let c = str(b["cls"]) else { continue }
            if counts[c] == nil { order.append(c) }
            counts[c, default: 0] += 1
        }
        p.objects = order.map { ($0, counts[$0] ?? 1) }
        if let o = str(d["ocr"]) {
            p.ocr = String(o.prefix(600)).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        p.sharpness = num(d["sharpn"]); p.faceQuality = num(d["faceq"])
        p.pick = int(d["pick"]) ?? 0
        p.focusMeasured = d["focusn"] is NSNumber
        if let q = d["quality"] as? [String: Any] {
            p.quality = Quality(focusRank: num(q["focusRank"]), aestheticRank: num(q["aestheticRank"]), aesthetic: num(q["aesthetic"]),
                                eyesChecked: int(q["eyesChecked"]) ?? 0, eyesClosed: int(q["eyesClosed"]) ?? 0,
                                rejectLabels: (q["rejectLabels"] as? [Any] ?? []).compactMap { $0 as? String })
        }
        if let b = num(d["bright"]) {
            p.dark = b < 0.2 || (num(d["clip_lo"]) ?? 0) > 0.5
            p.bright = b > 0.8 || (num(d["clip_hi"]) ?? 0) > 0.3
        }
        if let b = int(d["burst"]) { p.burst = (b, int(d["burst_size"]) ?? 0, (int(d["burst_best"]) ?? 0) != 0) }
        p.similar = (d["similar"] as? Bool) ?? ((int(d["similar"]) ?? 0) != 0)
        return p
    }

    static func trim(_ v: Double, _ places: Int) -> String {
        let s = String(format: "%.\(places)f", v)
        return s.contains(".") ? String(s.reversed().drop(while: { $0 == "0" }).drop(while: { $0 == "." }).reversed()) : s
    }

    static func utc(_ f: Date.FormatStyle) -> Date.FormatStyle {
        var f = f
        f.timeZone = TimeZone(identifier: "UTC")!  // the server's times are the camera's clock, kept as UTC
        return f
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// The info panel beside the photo on a wide screen (iPad, Mac), with everything the web app's panel shows: caption,
/// date, file and folder, people with their faces, tags, the place on a map, details, camera, the file's path and the
/// AI analysis. A tap on a date, person, tag, place, camera or detected thing shows the photos that share it.
struct PhotoInfoFull: View {
    let photo: Int
    let open: (String) -> Void
    @State private var d: PhotoDetail?
    @State private var failed = false
    @State private var rejected: Int?  // marked rejected from here (the panel's copy is not reloaded)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let d { content(d) } else if failed {
                    Text("Couldn't load the details of this photo.").foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: photo) {
            d = nil
            d = await PhotoDetail.load(photo)
            failed = d == nil
        }
    }

    @ViewBuilder private func content(_ d: PhotoDetail) -> some View {
        if let t = d.title { Text(t).font(.title3.bold()).textSelection(.enabled) }
        if let c = d.caption { Text(c).foregroundStyle(.secondary).textSelection(.enabled) }
        if let date = d.date, let n = d.precision {
            // an approximate date: only what is known, never the placeholder day
            let y = String((d.day ?? "").prefix(4)), ym = String((d.day ?? "").prefix(7))
            let last = Calendar(identifier: .gregorian).range(of: .day, in: .month, for: date).map { $0.count } ?? 31
            let span: String? = n == 2 ? "from=\(y)-01-01&to=\(y)-12-31" : n == 1 ? "from=\(ym)-01&to=\(ym)-\(String(format: "%02d", last))" : nil
            row("calendar") {
                link(PhotoDates.text(date.timeIntervalSince1970, precision: n), span.map { "#/photos?\($0)&sort=old" })
            } sub: {
                Text(n == 1 ? "Approximate date · the day is not known" : n == 2 ? "Approximate date · only the year is known"
                     : "Sorted under \(PhotoDates.text(date.timeIntervalSince1970, precision: nil, time: false)), a placeholder")
                    .foregroundStyle(.orange)
            }
        } else if let date = d.date {
            row("calendar") {
                link(date.formatted(PhotoDetail.utc(.dateTime.weekday(.wide).month(.wide).day().year())), d.day.map { "#/photos?from=\($0)&to=\($0)&sort=old" })
            } sub: { Text(date.formatted(PhotoDetail.utc(.dateTime.hour().minute()))) }
        }
        row(d.video ? "video" : "photo") { Text(d.name).textSelection(.enabled) } sub: { Text(fileLine(d)) }
        if let f = d.folder { row("folder") { link(f.path, "#/photos?album=\(f.id)&sort=old") } sub: { Text("Folder") } }
        if d.versions.count > 1 {
            row("square.on.square") {
                link(d.versions.enumerated().map { $1.original ? "Original" : ($1.id == d.id ? "This version" : "Version \($0)") }.joined(separator: " · "),
                     "#/photos?ids=" + d.versions.map { String($0.id) }.joined(separator: ","))
            } sub: { Text("Versions") }
        }
        if d.rating > 0 {
            row("star") { Text(String(repeating: "★", count: min(d.rating, 5)) + String(repeating: "☆", count: max(0, 5 - d.rating))) } sub: { Text("Rating") }
        }
        if !d.faces.isEmpty {
            heading("People")
            ForEach(d.faces) { f in faceRow(d, f) }
        }
        if !d.tags.isEmpty {
            heading("Tags")
            FlowLayout(spacing: 6) {
                ForEach(d.tags, id: \.id) { t in chip(t.name, symbol: nil) { open("#/photos?tag=\(t.id)") } }
            }
        }
        if let lat = d.lat, let lon = d.lon { location(d, lat, lon) }
        if !d.details.isEmpty || d.creator != nil {
            heading("Details")
            if let c = d.creator { kv("Creator") { link(c, "#/photos?" + q(["creator": c])) } }
            ForEach(Array(d.details.enumerated()), id: \.offset) { _, p in kv(p.0) { Text(p.1).textSelection(.enabled) } }
        }
        if d.camera != nil || d.exposure != nil {
            heading("Camera")
            kv("Camera") { if let c = d.camera { link(c, "#/photos?" + q(["camera": c])) } else { Text("Unknown camera") } }
            if let l = d.lens { kv("Lens") { link(l, "#/photos?" + q(["lens": l])) } }
            if let e = d.exposure { kv("Exposure") { Text(e) } }
        }
        heading("File")
        Text(d.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        if d.hasAI { ai(d) }
    }

    // MARK: sections

    @ViewBuilder private func faceRow(_ d: PhotoDetail, _ f: PhotoDetail.Face) -> some View {
        let named = f.kind == .confirmed || f.kind == .tagOnly
        Button {
            if named, let tag = f.tag { open("#/photos?tag=\(tag)") }
        } label: {
            HStack(spacing: 10) {
                FaceThumb(crop: f.rect.count == 4 ? "facecrop/\(d.id)/\(f.rect[0])/\(f.rect[1])/\(f.rect[2])/\(f.rect[3]).jpg" : nil,
                          badge: f.tag.map { "face/\($0)" })
                switch f.kind {
                case .confirmed, .tagOnly: Text(f.name ?? "Someone").foregroundStyle(.primary)
                case .suggested: Text("Suggestion: ").italic().foregroundStyle(.secondary) + Text(f.name ?? "").foregroundStyle(.primary)
                case .unknown: Text("Unknown face").italic().foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if f.kind == .tagOnly { Text("no face box").font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .buttonStyle(.plain)
        .disabled(!named)
    }

    @ViewBuilder private func location(_ d: PhotoDetail, _ lat: Double, _ lon: Double) -> some View {
        heading("Location")
        let parts: [(String, String)] = [
            d.place.map { ($0, "#/photos?" + q(["place": $0, "region": d.region])) },
            d.region.map { ($0, "#/photos?" + q(["region": $0])) },
            d.country.map { ($0, "#/photos?" + q(["country": $0])) },
        ].compactMap { $0 }
        if !parts.isEmpty {
            // one line of text that wraps as words do, each part its own link
            Text(parts.enumerated().reduce(into: AttributedString()) { out, e in
                if e.offset > 0 { out += AttributedString(", ") }
                var a = AttributedString(e.element.0)
                a.link = URL(string: "iopix-route:" + (e.element.1.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""))
                out += a
            })
            .environment(\.openURL, OpenURLAction { url in
                open(url.absoluteString.dropFirst("iopix-route:".count).removingPercentEncoding ?? "")
                return .handled
            })
        }
        if let acc = d.accuracy {
            Label("Approximate location · within about \(distance(acc))", systemImage: "mappin.circle")
                .font(.caption).foregroundStyle(.orange)
        }
        let spot = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        Map(initialPosition: .region(MKCoordinateRegion(center: spot, latitudinalMeters: max(1500, (d.accuracy ?? 0) * 3),
                                                        longitudinalMeters: max(1500, (d.accuracy ?? 0) * 3)))) {
            if let acc = d.accuracy {
                MapCircle(center: spot, radius: acc).foregroundStyle(.orange.opacity(0.15)).stroke(.orange, lineWidth: 1)
            } else {
                Marker("", coordinate: spot)
            }
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
        .id("\(d.id)")
        row("mappin.and.ellipse") {
            Text(String(format: "%.5f, %.5f", lat, lon)).textSelection(.enabled)
        } sub: {
            HStack(spacing: 4) {
                if let alt = d.alt, alt != 0 { Text("\(Int(alt.rounded())) m altitude ·") }
                if let f = d.facing { Text("facing \(Int(f.rounded()))° ·") }
                if let url = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(d.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Photo")") {
                    Link("Open in Maps", destination: url)
                }
            }
        }
    }

    @ViewBuilder private func ai(_ d: PhotoDetail) -> some View {
        heading("AI analysis")
        if let c = d.captionAI { Text(c).italic().foregroundStyle(.secondary).textSelection(.enabled) }
        if !d.concepts.isEmpty {
            sub("Detected")
            FlowLayout(spacing: 6) {
                ForEach(d.concepts, id: \.name) { c in chip(c.name, symbol: "sparkles") { open("#/photos?" + q(["concept": c.name])) } }
            }
        }
        if !d.objects.isEmpty {
            sub("Objects")
            FlowLayout(spacing: 6) {
                ForEach(d.objects, id: \.name) { o in chip(o.n > 1 ? "\(o.name) ×\(o.n)" : o.name, symbol: nil) { open("#/photos?" + q(["obj": o.name])) } }
            }
        }
        if let t = d.ocr {
            row("text.viewfinder") { Text(t).font(.callout).textSelection(.enabled) } sub: { Text("Text in the picture") }
        }
        if let q = d.quality {
            qualityRow(d, q)
        } else if let s = d.sharpness {
            row("sparkles") { Text("Sharper than \(Int((s * 100).rounded()))% of your photos") } sub: {
                Text([d.faceQuality.map { "Face quality \(Int(($0 * 100).rounded())) / 100" }, d.dark ? "Very dark" : nil, d.bright ? "Very bright" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
            }
        }
        if let b = d.burst {
            row("square.stack.3d.up") { link("Part of a burst of \(b.size) frames", "#/photos?burst=\(b.id)&sort=old") } sub: {
                Text(b.best ? "Picked as the best frame" : "Not the best frame")
            }
        }
        if d.similar && !d.video {
            row("sparkles") { link("More photos like this", "#/photos?like=\(d.id)") } sub: { EmptyView() }
        }
    }

    /// Focus and look as ranks in the library, closed eyes, and why it looks like a reject, as the web app's panel.
    @ViewBuilder private func qualityRow(_ d: PhotoDetail, _ q: PhotoDetail.Quality) -> some View {
        let pct = { (v: Double) in Int((v * 100).rounded()) }
        row("sparkles") {
            VStack(alignment: .leading, spacing: 2) {
                if let f = q.focusRank { Text("\(d.focusMeasured ? "In focus more than" : "Sharper than") \(pct(f))% of your photos") }
                if let a = q.aestheticRank, let s = q.aesthetic { Text("Looks better than \(pct(a))% of them (aesthetic score \(String(format: "%.1f", s)) / 10)") }
            }
        } sub: {
            VStack(alignment: .leading, spacing: 4) {
                let small = [
                    q.eyesChecked > 0 ? (q.eyesClosed > 0 ? "Eyes closed on \(q.eyesClosed) of \(q.eyesChecked) \(q.eyesChecked == 1 ? "face" : "faces") checked"
                                                        : "Eyes open on \(q.eyesChecked == 1 ? "the face" : "all \(q.eyesChecked) faces") checked") : nil,
                    d.faceQuality.map { "Face sharpness \(pct($0)) / 100" }, d.dark ? "Very dark" : nil, d.bright ? "Very bright" : nil,
                ].compactMap { $0 }
                if !small.isEmpty { Text(small.joined(separator: " · ")) }
                if !q.rejectLabels.isEmpty {
                    (Text("Likely reject: ").bold() + Text(q.rejectLabels.joined(separator: ", ").lowercased())).foregroundStyle(.orange)
                    if d.pick == 1 || rejected == d.id {
                        Text("Marked rejected")
                    } else if EditRights.shared.canWrite {
                        Button("Mark as rejected") {
                            Task {
                                if (try? await EditAPI.post("api/edit", ["ids": [d.id], "changes": ["pick": 1]])) != nil { rejected = d.id }
                            }
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    // MARK: pieces

    private func heading(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.6).padding(.top, 8)
    }

    private func sub(_ t: String) -> some View {
        Text(t).font(.caption).foregroundStyle(.secondary)
    }

    private func row<A: View, B: View>(_ symbol: String, @ViewBuilder _ main: () -> A, @ViewBuilder sub: () -> B) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                main()
                sub().font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func kv<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            v().font(.callout)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func link(_ text: String, _ route: String?) -> some View {
        if let route {
            Button(text) { open(route) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .multilineTextAlignment(.leading)
        } else {
            Text(text)
        }
    }

    private func chip(_ text: String, symbol: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.caption2) }
                Text(text).font(.callout)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.secondary.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func fileLine(_ d: PhotoDetail) -> String {
        let mp = Double(d.w * d.h) / 1e6
        return [d.video ? nil : (mp >= 1 ? String(format: "%.1f MP", mp) : String(format: "%.2f MP", mp)),
                d.w > 0 ? "\(d.w) × \(d.h)" : nil,
                d.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(d.size), countStyle: .file) : nil,
                d.fmt].compactMap { $0 }.joined(separator: " · ")
    }

    private func distance(_ m: Double) -> String {
        Measurement(value: m, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private func q(_ pairs: [String: String?]) -> String {
        var c = URLComponents()
        c.queryItems = pairs.sorted { $0.key < $1.key }.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        return (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }
}

/// A face's picture: its crop from this photo, or the person's badge picture when the crop can't be made.
private struct FaceThumb: View {
    let crop: String?
    let badge: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.15))
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
        .task(id: crop ?? badge) {
            for path in [crop, badge].compactMap({ $0 }) {
                var i = ImageCache.shared.cached(path)
                if i == nil { i = await ImageCache.shared.image(path) }
                if let i { image = i; return }
            }
        }
    }
}
