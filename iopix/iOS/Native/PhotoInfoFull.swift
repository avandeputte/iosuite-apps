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
    /// A year for a "Date unknown" photo from how old its people look (iopix 1.82, editors only).
    var suggestion: DateSuggestion?
    /// Editors' other suggestions (iopix 1.94 and later): where it was probably taken, which way up it belongs, and
    /// people probably in it from a shirt number or their clothes.
    var placeSuggestion: PlaceSuggestion?
    var rotation: RotationFinding?
    var people: [(kind: ManagePersonSuggestScreen.Kind, s: PersonSuggestion)] = []
    /// Shirt numbers read in it.
    var jerseys: [String] = []
    /// A video's chapters (seconds) and what is said in it.
    var chapters: [Double] = []
    var transcript: String?
    var pick = 0
    var burst: (id: Int, size: Int, best: Bool, bestID: Int?)?
    var similar = false

    var hasAI: Bool {
        captionAI != nil || !concepts.isEmpty || !objects.isEmpty || !jerseys.isEmpty || ocr != nil || sharpness != nil || quality != nil || burst != nil || (similar && !video)
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
        p.suggestion = (d["dateSuggestion"] as? [String: Any]).flatMap(DateSuggestion.init(json:))
        p.placeSuggestion = (d["placeSuggestion"] as? [String: Any]).flatMap(PlaceSuggestion.init(json:))
        p.rotation = (d["rotationSuggestion"] as? [String: Any]).flatMap(RotationFinding.init(json:))
        p.people = (d["jerseySuggestions"] as? [[String: Any]] ?? []).compactMap { PersonSuggestion(json: $0, kind: .jersey).map { (.jersey, $0) } }
            + (d["clothingSuggestions"] as? [[String: Any]] ?? []).compactMap { PersonSuggestion(json: $0, kind: .clothing).map { (.clothing, $0) } }
        var numbers: [String] = []
        for j in d["jerseys"] as? [[String: Any]] ?? [] { if let n = j["number"].map({ "\($0)" }), !numbers.contains(n) { numbers.append(n) } }
        p.jerseys = numbers
        if let v = d["videoInfo"] as? [String: Any] {
            p.chapters = (v["chapters"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
            p.transcript = str(v["transcript"])
        }
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
        if let b = int(d["burst"]) { p.burst = (b, int(d["burst_size"]) ?? 0, (int(d["burst_best"]) ?? 0) != 0, int(d["burst_best_id"])) }
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
    /// Set for accounts that can change photos: the Actions menu and the face, tag and location shortcuts.
    var edit: (() -> Void)? = nil
    @State private var d: PhotoDetail?
    @State private var failed = false
    /// The sections hidden with the gear (the web app's info_hide, kept with the account when signed in).
    @AppStorage("iopix.pref.info_hide") private var hiddenList = ""
    @State private var faceMenu: PhotoDetail.Face?
    @State private var naming: PhotoDetail.Face?
    @State private var addPerson = false
    @State private var template = false
    @State private var metadata = false
    @State private var album = false
    @State private var toast: String?
    @State private var logKey = 0
    @EnvironmentObject private var store: LibraryStore
    @State private var used: Int?   // a suggested year saved from here (the panel's copy is not reloaded)
    @State private var handled: Set<String> = []  // other suggestions used or dismissed from here

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
        .onReceive(NotificationCenter.default.publisher(for: .iopixPhotoChanged)) { n in
            // changed anywhere (the viewer's boxes, the faces editor, the edit pane): the details follow at once
            if (n.userInfo?["photo"] as? Int) == photo { Task { await reload() } }
        }
        .task {
            // the account's choice of sections, as the web app saved it
            if let me = try? await IopixClient.shared.json("api/auth/me"), let h = (me["settings"] as? [String: Any])?["info_hide"] as? String { hiddenList = h }
        }
        .confirmationDialog(faceMenu.map(faceTitle) ?? "Face", isPresented: Binding(get: { faceMenu != nil }, set: { if !$0 { faceMenu = nil } }), titleVisibility: .visible) {
            if let f = faceMenu { faceActions(f) }
        }
        .sheet(item: $naming) { f in
            EditPersonPicker(photo: photo, title: f.kind == .confirmed ? "Who is this instead?" : "Who is this?") { person in
                Task { await faceOp(["op": "name", "image": photo, "rect": f.rect, "tag": person.id], "Named \(person.name).") }
            }
        }
        .sheet(isPresented: $addPerson) {
            EditPersonPicker(photo: photo, title: d?.video == true ? "Who is in this video?" : "Who is in this photo?") { person in
                Task { await faceOp(["op": "tagonly", "image": photo, "tag": person.id], "Added \(person.name).") }
            }
        }
        .sheet(isPresented: $template) { BulkTemplateSheet(ids: [photo]) { Task { await reload() } } }
        .sheet(isPresented: $metadata) { EditMetadataView(photo: photo) { Task { await reload() } } }
        .sheet(isPresented: $album) { BulkAlbumSheet(ids: [photo]).environmentObject(store) }
        .editToast($toast)
    }

    private func reload() async {
        d = await PhotoDetail.load(photo)
        logKey += 1
    }

    private func hidden(_ key: String) -> Bool { hiddenList.split(separator: ",").contains(Substring(key)) }

    private func setHidden(_ key: String, _ hide: Bool) {
        var set = Set(hiddenList.split(separator: ",").map(String.init).filter { !$0.isEmpty })
        if hide { set.insert(key) } else { set.remove(key) }
        hiddenList = set.sorted().joined(separator: ",")
        Task { _ = try? await EditAPI.post("api/auth/settings", ["info_hide": hiddenList]) }  // with the account, when signed in
    }

    /// The web app's Actions menu and the gear that chooses the sections, above the details.
    @ViewBuilder private func actionsBar(_ d: PhotoDetail) -> some View {
        HStack(spacing: 8) {
            if edit != nil {
                Menu {
                    if !d.video {
                        Section(d.video ? "People" : "Faces") {
                            Button { Task { await detectFaces() } } label: { Label("Detect faces", systemImage: "viewfinder") }
                            let unnamed = d.faces.filter { $0.kind == .unknown }
                            if !unnamed.isEmpty {
                                Button { Task { await removeUnnamed(unnamed) } } label: { Label("Remove all unnamed face regions (\(unnamed.count))", systemImage: "person.crop.square.badge.xmark") }
                            }
                        }
                    }
                    Button { addPerson = true } label: { Label(d.video ? "Add a person to this video…" : "Add a person without a face box…", systemImage: "person.badge.plus") }
                    if let lat = d.lat, let lon = d.lon {
                        Section("Around this photo") {
                            if let day = d.day { Button { open("#/map?from=\(day)&to=\(day)&trail=\(day)") } label: { Label("Day's trail on the map", systemImage: "point.topleft.down.to.point.bottomright.curvepath") } }
                            Button { open("#/photos?bbox=" + [lat - 0.01, lon - 0.015, lat + 0.01, lon + 0.015].map { String(format: "%.4f", $0) }.joined(separator: ",")) } label: { Label("Photos nearby", systemImage: "mappin.and.ellipse") }
                        }
                    }
                    Section("Metadata") {
                        Button { edit?() } label: { Label("Change the date, location, title, tags…", systemImage: "slider.horizontal.3") }
                        Button { template = true } label: { Label("Apply a metadata template…", systemImage: "doc.text") }
                        Button { metadata = true } label: { Label("All metadata…", systemImage: "list.bullet.rectangle") }
                    }
                    Section {
                        Button { album = true } label: { Label("Add to album…", systemImage: "rectangle.stack.badge.plus") }
                        Button { open("#/history?photo=\(d.id)") } label: { Label("Edit log", systemImage: "clock.arrow.circlepath") }
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle").font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(Color.secondary.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(AdminDisplayScreen.infoSections, id: \.0) { key, label in
                    Toggle(label, isOn: Binding(get: { !hidden(key) }, set: { setHidden(key, !$0) }))
                }
            } label: { Image(systemName: "gearshape").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose the sections")
        }
    }

    private func detectFaces() async {
        do {
            _ = try await EditAPI.post("api/faces/detect", ["ids": [photo]])
            toast = "Looking for faces…"
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await PhotoChange.changed(photo)
        } catch { toast = error.localizedDescription }
    }

    private func removeUnnamed(_ faces: [PhotoDetail.Face]) async {
        do {
            try await PhotoChange.faceOps(faces.map { ["op": "remove", "image": photo, "rect": $0.rect] }, photo: photo)
            toast = "\(faces.count) unnamed face region\(faces.count == 1 ? "" : "s") removed."
        } catch { toast = error.localizedDescription }
    }

    private func faceTitle(_ f: PhotoDetail.Face) -> String {
        switch f.kind {
        case .confirmed, .tagOnly: return f.name ?? "Face"
        case .suggested: return "Is this \(f.name ?? "them")?"
        case .unknown: return "Unknown face"
        }
    }

    /// The web app's face menu, for a row in People.
    @ViewBuilder private func faceActions(_ f: PhotoDetail.Face) -> some View {
        let rect = f.rect
        switch f.kind {
        case .tagOnly:
            if let t = f.tag { Button("All photos of \(f.name ?? "them")") { open("#/photos?tag=\(t)") } }
            if let t = f.tag { Button("Take \(f.name ?? "them") off this photo", role: .destructive) { Task { await faceOp(["op": "untag", "image": photo, "tag": t], "\(f.name ?? "") taken off this photo.") } } }
        case .confirmed:
            if let t = f.tag { Button("All photos of \(f.name ?? "them")") { open("#/photos?tag=\(t)") } }
            Button("Someone else…") { naming = f }
            if let t = f.tag { Button("Use as \(f.name ?? "their") badge picture") { Task { await badge(t, f.name ?? "") } } }
            Button("Forget the name") { Task { await faceOp(["op": "unknown", "image": photo, "rect": rect], "Name removed; the face stays as unknown.") } }
            Button("Not a face to name (ignore)") { Task { await faceOp(["op": "ignore", "image": photo, "rect": rect], "Face ignored.") } }
            Button("Remove this face", role: .destructive) { Task { await faceOp(["op": "remove", "image": photo, "rect": rect], "Face removed.") } }
        case .suggested:
            Button("Yes, this is \(f.name ?? "them")") { Task { await faceOp(["op": "confirm", "image": photo, "rect": rect], "Confirmed.") } }
            Button("No, someone else…") { naming = f }
            Button("Not a face to name (ignore)") { Task { await faceOp(["op": "ignore", "image": photo, "rect": rect], "Face ignored.") } }
            Button("Remove this box", role: .destructive) { Task { await faceOp(["op": "remove", "image": photo, "rect": rect], "Removed.") } }
        case .unknown:
            Button("Who is this?…") { naming = f }
            Button("Not a face to name (ignore)") { Task { await faceOp(["op": "ignore", "image": photo, "rect": rect], "Face ignored.") } }
            Button("Remove this box", role: .destructive) { Task { await faceOp(["op": "remove", "image": photo, "rect": rect], "Removed.") } }
        }
    }

    private func faceOp(_ o: [String: Any], _ said: String) async {
        do { try await PhotoChange.faceOp(o); toast = said }
        catch { toast = "That face change did not go through: \(error.localizedDescription)" }
    }

    private func badge(_ tag: Int, _ name: String) async {
        do { _ = try await EditAPI.post("api/tags/op", ["op": "icon", "id": tag, "photo": photo]); toast = "Now \(name)'s badge picture." }
        catch { toast = error.localizedDescription }
    }

    private func removeTag(_ t: (id: Int, name: String)) async {
        do { _ = try await EditAPI.edit([photo], ["remove_tags": [t.id]]); toast = "\(t.name) removed."; await PhotoChange.changed(photo, faces: false) }
        catch { toast = error.localizedDescription }
    }

    @ViewBuilder private func content(_ d: PhotoDetail) -> some View {
        actionsBar(d)
        if !hidden("caption") {
            if let t = d.title { SelectableText(t, style: .title3, bold: true) }
            if let c = d.caption { SelectableText(c, secondary: true) }
        }
        if hidden("date") {
        } else if let date = d.date, let n = d.precision {
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
        if let g = d.suggestion, used != d.id, !hidden("date") { suggestionRow(g) }
        if let r = d.rotation, !handled.contains("rotation"), !hidden("file") { rotationRow(r) }
        if !hidden("file") {
            row(d.video ? "video" : "photo") { SelectableText(d.name) } sub: { Text(fileLine(d)) }
            if let f = d.folder { row("folder") { link(f.path, "#/photos?album=\(f.id)&sort=old") } sub: { Text("Folder") } }
            if d.versions.count > 1 {
                // each version opens in the viewer, as on the web
                row("square.on.square") {
                    HStack(spacing: 4) {
                        ForEach(Array(d.versions.enumerated()), id: \.offset) { i, v in
                            if i > 0 { Text("·").foregroundStyle(.secondary) }
                            let label = v.original ? "Original" : (v.id == d.id ? "This version" : "Version \(i)")
                            if v.id == d.id { Text(label) } else { link(label, "#/photos?p=\(v.id)") }
                        }
                    }
                } sub: { Text("Versions") }
            }
        }
        if d.rating > 0, !hidden("details") {
            row("star") { Text(String(repeating: "★", count: min(d.rating, 5)) + String(repeating: "☆", count: max(0, 5 - d.rating))) } sub: { Text("Rating") }
        }
        let people = d.people.filter { !handled.contains($0.s.id) }
        if !d.faces.isEmpty || !people.isEmpty, !hidden("people") {
            heading("People")
            ForEach(d.faces) { f in faceRow(d, f) }
            ForEach(people, id: \.s.id) { p in personSuggestionRow(p.kind, p.s) }
        }
        if d.video, !d.chapters.isEmpty || d.transcript != nil, !hidden("file") {
            heading("In this video")
            if !d.chapters.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(d.chapters.enumerated()), id: \.offset) { _, t in
                        chip(Self.clock(t), symbol: "play.fill") {
                            NotificationCenter.default.post(name: .iopixVideoSeek, object: nil, userInfo: ["photo": d.id, "t": t])
                        }
                    }
                }
            }
            if let t = d.transcript { SelectableText(t, style: .callout, secondary: true) }
        }
        if !hidden("tags"), !d.tags.isEmpty || edit != nil {
            heading("Tags")
            FlowLayout(spacing: 6) {
                ForEach(d.tags, id: \.id) { t in
                    chip(t.name, symbol: nil) { open("#/photos?tag=\(t.id)") }
                        .contextMenu {
                            if edit != nil {
                                Button { Task { await badge(t.id, t.name) } } label: { Label("Use this photo as the tag's picture", systemImage: "photo") }
                                Button(role: .destructive) { Task { await removeTag(t) } } label: { Label("Remove \(t.name)", systemImage: "xmark") }
                            }
                        }
                }
                if edit != nil { chip("Add a tag…", symbol: "plus") { edit?() } }
            }
        }
        if hidden("location") {
        } else if let lat = d.lat, let lon = d.lon {
            location(d, lat, lon)
        } else if edit != nil {
            heading("Location")
            if let g = d.placeSuggestion, !handled.contains("place") { placeRow(g) }
            Button("Set the location on the map…") { edit?() }.buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.callout)
        }
        if !hidden("details"), !d.details.isEmpty || d.creator != nil {
            heading("Details")
            if let c = d.creator { kv("Creator") { link(c, "#/photos?" + q(["creator": c])) } }
            ForEach(Array(d.details.enumerated()), id: \.offset) { _, p in kv(p.0) { SelectableText(p.1) } }
        }
        if !hidden("camera"), d.camera != nil || d.exposure != nil {
            heading("Camera")
            kv("Camera") { if let c = d.camera { link(c, "#/photos?" + q(["camera": c])) } else { Text("Unknown camera") } }
            if let l = d.lens { kv("Lens") { link(l, "#/photos?" + q(["lens": l])) } }
            if let e = d.exposure { kv("Exposure") { Text(e) } }
        }
        if !hidden("file") {
            heading("File")
            SelectableText(d.path, style: .caption1, secondary: true)
        }
        if d.hasAI, !hidden("ai") { ai(d) }
        if !hidden("history") {
            heading("Edit log")
            InlineEditLog(photo: d.id, canWrite: edit != nil, open: open) { Task { await reload() } }.id(logKey)
        }
    }

    // MARK: sections

    @ViewBuilder private func faceRow(_ d: PhotoDetail, _ f: PhotoDetail.Face) -> some View {
        let named = f.kind == .confirmed || f.kind == .tagOnly
        Button {
            // a named person opens their photos; with editing rights every row has the web app's face menu
            if edit != nil { faceMenu = f } else if named, let tag = f.tag { open("#/photos?tag=\(tag)") }
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
        .disabled(!named && edit == nil)
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
            SelectableText(String(format: "%.5f, %.5f", lat, lon))
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
        if let c = d.captionAI { SelectableText(c, italic: true, secondary: true) }
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
            row("text.viewfinder") { SelectableText(t, style: .callout) } sub: { Text("Text in the picture") }
        }
        if let q = d.quality {
            qualityRow(d, q)
        } else if let s = d.sharpness {
            row("sparkles") { Text("Sharper than \(Int((s * 100).rounded()))% of your photos") } sub: {
                Text([d.faceQuality.map { "Face quality \(Int(($0 * 100).rounded())) / 100" }, d.dark ? "Very dark" : nil, d.bright ? "Very bright" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
            }
        }
        if !d.jerseys.isEmpty {
            row("tshirt") {
                HStack(spacing: 4) {
                    ForEach(Array(d.jerseys.enumerated()), id: \.offset) { i, n in
                        if i > 0 { Text("·").foregroundStyle(.secondary) }
                        link("Number \(n)", "#/photos?jersey=\(n)")
                    }
                }
            } sub: { Text("Shirt numbers read") }
        }
        if let b = d.burst {
            row("square.stack.3d.up") { link("Part of a burst of \(b.size) frames", "#/photos?burst=\(b.id)&sort=old") } sub: {
                HStack(spacing: 4) {
                    Text(b.best ? "Picked as the best frame" : "Not the best frame")
                    if !b.best, let best = b.bestID {  // as the web app's panel: straight to it
                        Text("·")
                        Button("open the best frame") { open("#/photos?p=\(best)") }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                }
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
                if let f = q.focusRank { SelectableText("\(d.focusMeasured ? "In focus more than" : "Sharper than") \(pct(f))% of your photos") }
                if let a = q.aestheticRank, let s = q.aesthetic { SelectableText("Looks better than \(pct(a))% of them (aesthetic score \(String(format: "%.1f", s)) / 10)") }
            }
        } sub: {
            VStack(alignment: .leading, spacing: 4) {
                let small = [
                    q.eyesChecked > 0 ? (q.eyesClosed > 0 ? "Eyes closed on \(q.eyesClosed) of \(q.eyesChecked) \(q.eyesChecked == 1 ? "face" : "faces") checked"
                                                        : "Eyes open on \(q.eyesChecked == 1 ? "the face" : "all \(q.eyesChecked) faces") checked") : nil,
                    d.faceQuality.map { "Face sharpness \(pct($0)) / 100" }, d.dark ? "Very dark" : nil, d.bright ? "Very bright" : nil,
                ].compactMap { $0 }
                if !small.isEmpty { SelectableText(small.joined(separator: " · "), style: .footnote, secondary: true) }
                // a suggestion only: nothing in iopix sets the Rejected label (web 1.87.1)
                if !q.rejectLabels.isEmpty {
                    (Text("Likely reject: ").bold() + Text(q.rejectLabels.joined(separator: ", ").lowercased())).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder private func placeRow(_ g: PlaceSuggestion) -> some View {
        row("sparkles") {
            Text("Probably \(g.whereText)") + Text(" (\(g.within))").foregroundStyle(.secondary)
        } sub: {
            VStack(alignment: .leading, spacing: 4) {
                if !g.text.isEmpty { Text(g.text) }
                HStack(spacing: 12) {
                    if EditRights.shared.canWrite {
                        Button("Use") {
                            Task { await act("place", "Position saved.") {
                                _ = try await EditAPI.post("api/edit", ["ids": [g.id], "changes": ["gps": ["lat": g.lat, "lon": g.lon, "accuracy": Int((g.km * 1000).rounded())]]])
                            } }
                        }
                    }
                    Button("All suggestions") { open("#/placesuggest") }
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder private func rotationRow(_ r: RotationFinding) -> some View {
        row("rotate.right") {
            Text("Looks \(r.text)")
        } sub: {
            HStack(spacing: 12) {
                if EditRights.shared.canWrite {
                    Button(r.label) {
                        Task { await act("rotation", "Rotated.") {
                            let x = try await EditAPI.post("api/photos/transform", ["ids": [r.id], "op": r.op])
                            if let f = (x["failed"] as? [[String: Any]])?.first { throw EditAPI.Failure(message: f["error"] as? String ?? "Not rotated.") }
                            NotificationCenter.default.post(name: .iopixPhotoChanged, object: nil, userInfo: ["photo": r.id])
                        } }
                    }
                    Button("It's fine") { Task { await act("rotation", nil) { _ = try await EditAPI.post("api/rotation/dismiss", ["photos": [r.id]]) } } }
                }
            }
            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder private func personSuggestionRow(_ kind: ManagePersonSuggestScreen.Kind, _ s: PersonSuggestion) -> some View {
        row(kind == .jersey ? "tshirt" : "person.fill.questionmark") {
            Text("Probably \(s.name)")
        } sub: {
            VStack(alignment: .leading, spacing: 4) {
                Text(kind == .jersey ? "\(s.headline) · \(s.detail)" : s.detail)
                if EditRights.shared.canWrite {
                    HStack(spacing: 12) {
                        Button("Tag") { Task { await act(s.id, "Added \(s.name).") { try await EditAPI.faceOps([["op": "tagonly", "image": s.photo, "tag": s.tag]]) } } }
                        Button("Not them") { Task { await act(s.id, nil) { _ = try await EditAPI.post("api/suggestions/dismiss", ["kind": kind.rawValue, "pairs": [[s.photo, s.tag]]]) } } }
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    /// Runs a suggestion's button, then hides the suggestion and reloads the details.
    private func act(_ key: String, _ done: String?, _ work: () async throws -> Void) async {
        do {
            try await work()
            handled.insert(key)
            if let done { toast = done }
            NotificationCenter.default.post(name: .iopixPhotosChanged, object: nil)
            await reload()
        } catch {
            toast = error.localizedDescription
        }
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    @ViewBuilder private func suggestionRow(_ g: DateSuggestion) -> some View {
        row("sparkles") {
            Text("Looks like about \(String(g.year))") + Text(g.range.isEmpty ? "" : " (\(g.range))").foregroundStyle(.secondary)
        } sub: {
            VStack(alignment: .leading, spacing: 4) {
                Text(g.why)
                HStack(spacing: 12) {
                    if EditRights.shared.canWrite {
                        Button("Use \(String(g.year))") {
                            Task { if (try? await DateSuggestion.use([g])) != nil { used = g.id; NotificationCenter.default.post(name: .iopixPhotosChanged, object: nil) } }
                        }
                    }
                    Button("All suggestions") { open("#/datesuggest") }
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
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


/// The last changes iopix made to this photo, with their undo, inside the info pane (the web app's Edit log section).
struct InlineEditLog: View {
    let photo: Int
    let canWrite: Bool
    let open: (String) -> Void
    var restored: () -> Void = {}
    @State private var entries: [EditHistoryView.Entry]?
    @State private var total = 0
    @State private var working: Int?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let entries {
                if entries.isEmpty { Text("ioPix hasn't changed this photo.").font(.caption).foregroundStyle(.secondary) }
                ForEach(entries) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(EditHistoryView.actions[e.action] ?? e.action.capitalized).font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1).background(Hue.indigo.opacity(0.14), in: Capsule())
                            SelectableText(e.summary, style: .footnote)
                        }
                        HStack(spacing: 10) {
                            Text(Date(timeIntervalSince1970: e.ts).formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                            if canWrite {
                                ForEach(e.restore, id: \.self) { k in
                                    Button(EditHistoryView.restoreLabels[k] ?? k.capitalized) { Task { await restore(e, k) } }
                                        .font(.caption2).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                                }
                            }
                            if working == e.id { ProgressView().controlSize(.mini) }
                        }
                    }
                }
                if total > entries.count {
                    Button("All \(total) changes…") { open("#/history?photo=\(photo)") }.font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: photo) { await load() }
    }

    private func load() async {
        guard let r = try? await EditAPI.get("api/history", [URLQueryItem(name: "photo", value: "\(photo)"), URLQueryItem(name: "limit", value: "6")]) else { entries = []; return }
        total = (r["total"] as? NSNumber)?.intValue ?? 0
        entries = (r["entries"] as? [[String: Any]] ?? []).compactMap { e in
            guard let id = (e["id"] as? NSNumber)?.intValue else { return nil }
            return EditHistoryView.Entry(id: id, ts: (e["ts"] as? NSNumber)?.doubleValue ?? 0, user: e["user"] as? String ?? "",
                                         action: e["action"] as? String ?? "", summary: e["summary"] as? String ?? "", restore: e["restore"] as? [String] ?? [])
        }
    }

    private func restore(_ e: EditHistoryView.Entry, _ kind: String) async {
        working = e.id
        defer { working = nil }
        do {
            _ = try await EditAPI.post("api/history/\(e.id)/restore", ["kind": kind])
            note = kind == "deleted" ? "Photo restored." : "Restored."
            await PhotoChange.changed(photo)  // the picture's boxes and the pane follow, now and after the reindex
            restored()
            await load()
        } catch { note = error.localizedDescription }
    }
}
