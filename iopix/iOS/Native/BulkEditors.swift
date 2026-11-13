import SwiftUI
import MapKit
import UniformTypeIdentifiers

/// Metadata changes for one or many photos, through the server's edit path (sidecars, with the edit log and Undo).
enum BulkEdit {
    /// Sends `changes` (rating, pick, color, title, caption, taken, shift, gps, template, add_tags, remove_tags) for
    /// these photos. Says what happened in a message; false when nothing was saved.
    @MainActor
    @discardableResult
    static func apply(_ ids: [Int], _ changes: [String: Any], quiet: Bool = false) async -> Bool {
        do {
            let r = try await BulkAPI.post("api/edit", ["ids": ids, "changes": changes])
            let failed = r["failed"] as? [[String: Any]] ?? []
            let edited = (r["edited"] as? NSNumber)?.intValue ?? ids.count
            if let f = failed.first {
                BulkToast.shared.show("\(failed.count) couldn't be changed: \(f["error"] as? String ?? "")", seconds: 8)
            } else if !quiet {
                BulkToast.shared.show(edited == 1 ? "Saved." : "Saved for \(edited.formatted()) photos.")
            }
            return true
        } catch {
            BulkToast.shared.show("Couldn't save the change: \(error.localizedDescription)", seconds: 8)
            return false
        }
    }

    static func plural(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n.formatted()) \(word)s" }
}

// MARK: - tags

/// A tag picker: recent tags, a search over every keyword tag, and (for those who manage the library) a new tag,
/// typed as "Parent/New tag".
struct BulkTagPicker: View {
    var prompt = "Find a tag"
    var showRecent = true
    let pick: (BulkCatalog.Tag) -> Void
    @ObservedObject private var catalog = BulkCatalog.shared
    @State private var text = ""
    @State private var creating: String?

    private var keywordTags: [BulkCatalog.Tag] { catalog.tags.filter { !$0.person && !$0.full.hasPrefix("People") } }

    var body: some View {
        Group {
            if showRecent {
                let recent = catalog.recentTags.compactMap { catalog.tagByID[$0] }.filter { !$0.person }
                if !recent.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(recent) { t in
                            Button(t.name) { choose(t) }
                                .font(.subheadline).buttonStyle(.bordered).buttonBorderShape(.capsule)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { submit() }
            let f = text.trimmingCharacters(in: .whitespaces).lowercased()
            if !f.isEmpty {
                ForEach(keywordTags.filter { $0.full.lowercased().contains(f) }.prefix(30)) { t in
                    Button { choose(t) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name).foregroundStyle(.primary)
                            if t.full.contains("/") { Text(t.full.replacingOccurrences(of: "/", with: " › ")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if catalog.canManage, !keywordTags.contains(where: { $0.full.lowercased() == f }) {
                    Button { creating = text.trimmingCharacters(in: .whitespaces) } label: {
                        Label("Create the tag “\(text.trimmingCharacters(in: .whitespaces))”", systemImage: "plus")
                    }
                }
            }
        }
        .task { await catalog.load(); await catalog.loadRecentTags() }
        .confirmationDialog("Create the tag “\(creating ?? "")” in digiKam’s database?", isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } }),
                            titleVisibility: .visible) {
            Button("Create") { if let c = creating { Task { await create(c) } } }
        } message: { Text("digiKam must be closed; a backup is made first. Type “Parent/New tag” to put it under an existing tag.") }
    }

    private func submit() {
        let f = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let t = keywordTags.first(where: { $0.full.lowercased() == f || $0.name.lowercased() == f }) { choose(t) }
        else if catalog.canManage, !f.isEmpty { creating = text.trimmingCharacters(in: .whitespaces) }
    }

    private func choose(_ t: BulkCatalog.Tag) {
        text = ""
        pick(t)
        Task { await catalog.noteRecent([t.id]) }
    }

    private func create(_ full: String) async {
        var parts = full.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let name = parts.popLast() else { return }
        var parent = 0
        if !parts.isEmpty {
            let path = parts.joined(separator: "/").lowercased()
            guard let p = catalog.tags.first(where: { !$0.person && $0.full.lowercased() == path }) else {
                BulkToast.shared.show("The parent tag “\(parts.joined(separator: " › "))” doesn't exist."); return
            }
            parent = p.id
        }
        do {
            let r = try await BulkAPI.post("api/tags/op", ["op": "add", "parent": parent, "name": name])
            guard let id = (r["id"] as? NSNumber)?.intValue else { return }
            // the index takes a moment to list the new tag
            for _ in 0..<10 {
                await catalog.load(force: true)
                if let t = catalog.tagByID[id] { choose(t); return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            BulkToast.shared.show("Created “\(r["path"] as? String ?? name)”; it will appear shortly.")
        } catch {
            BulkToast.shared.show(error.localizedDescription)
        }
    }
}

/// Add or remove keyword tags on the whole selection; each tag applies as soon as it is picked.
struct BulkTagSheet: View {
    let ids: [Int]
    var changed: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BulkTagPicker(prompt: "Add a tag") { t in Task { if await BulkEdit.apply(ids, ["add_tags": [t.id]], quiet: true) { BulkToast.shared.show("Tagged “\(t.name)”."); changed() } } }
                } header: { Text("Add") } footer: { Text("Pick a recent tag or type to find one. Each tag is applied as soon as you pick it.") }
                Section("Remove") {
                    BulkTagPicker(prompt: "Remove a tag from all", showRecent: false) { t in Task { if await BulkEdit.apply(ids, ["remove_tags": [t.id]], quiet: true) { BulkToast.shared.show("Removed “\(t.name)”."); changed() } } }
                }
            }
            .navigationTitle("Tag \(BulkEdit.plural(ids.count, "photo"))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { BarText("Done") } } }
        }
    }
}

// MARK: - rating, labels, title, caption, date

/// Everything the web app's Edit dialog sets for many photos at once. Each change saves straight away.
struct BulkEditSheet: View {
    let ids: [Int]
    var changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var caption = ""
    @State private var taken = Date()
    @State private var known = DateKnown.exact
    @State private var knownYear = 0   // 0: each photo's own
    @State private var knownMonth = 1
    @State private var amount = 1
    @State private var unit = 3600

    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rating") {
                    HStack(spacing: 16) {
                        ForEach(1...5, id: \.self) { n in
                            Button { save(["rating": n]) } label: { Image(systemName: "star.fill").font(.title3).foregroundStyle(.yellow) }
                                .buttonStyle(.plain).accessibilityLabel("\(n) star\(n > 1 ? "s" : "")")
                                .overlay(alignment: .bottom) { Text("\(n)").font(.caption2).offset(y: 14).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("No rating") { save(["rating": 0]) }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 6)
                }
                Section("Labels") {
                    Menu("Pick label") {
                        ForEach(Array(["None", "Rejected", "Pending", "Accepted"].enumerated()), id: \.offset) { i, l in Button(l) { save(["pick": i]) } }
                    }
                    Menu("Colour label") {
                        ForEach(0..<BulkCatalog.colorNames.count, id: \.self) { i in Button(BulkCatalog.colorNames[i]) { save(["color": i]) } }
                    }
                }
                Section("Title") {
                    TextField("Title for all", text: $title)
                    Button("Apply title") { save(["title": title.trimmingCharacters(in: .whitespaces)], done: title.isEmpty ? "Title cleared." : "Title set.") }
                }
                Section("Caption") {
                    TextField("Caption for all", text: $caption, axis: .vertical).lineLimit(2...5)
                    Button("Apply caption") { save(["caption": caption.trimmingCharacters(in: .whitespaces)], done: caption.isEmpty ? "Caption cleared." : "Caption set.") }
                }
                Section {
                    Picker("Date known", selection: $known) { ForEach(DateKnown.allCases) { Text($0.label).tag($0) } }
                    switch known {
                    case .exact:
                        DatePicker("Set all to", selection: $taken, displayedComponents: [.date, .hourAndMinute])
                            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                        Button("Set date") { save(["taken": Self.stamp(taken)]) }
                    case .month, .year:
                        ApproxDateFields(known: known, year: $knownYear, month: $knownMonth, allowOwn: true)
                        Button("Set date") { saveApprox() }
                    case .unknown:
                        Button("Mark as unknown") { save(["date_precision": "unknown"], done: "Marked as date unknown.") }
                    }
                } header: { Text("Date") } footer: {
                    if let n = known.note(many: true) {
                        Text(n + (known == .exact ? "" : " With “Each photo's own”, each keeps its own \(known == .year ? "year" : "month and year")."))
                    }
                }
                if known == .exact {
                Section {
                    Stepper("Shift by \(amount)", value: $amount, in: 1...999)
                    Picker("Unit", selection: $unit) {
                        Text("hours").tag(3600); Text("minutes").tag(60); Text("days").tag(86400); Text("seconds").tag(1)
                    }
                    HStack {
                        Button("Later") { save(["shift": amount * unit]) }.buttonStyle(.bordered)
                        Button("Earlier") { save(["shift": -amount * unit]) }.buttonStyle(.bordered)
                    }
                } footer: {
                    Text("Shifting keeps each photo's own time and moves it by the same amount, for a camera clock that was wrong.")
                }
                }
            }
            .navigationTitle("Edit \(BulkEdit.plural(ids.count, "photo"))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { BarText("Done") } } }
        }
    }

    /// The camera's clock, written as the server takes it (YYYY-MM-DDTHH:MM:SS, no zone).
    /// Month and year, or year only, for all of them: the known part goes as "YYYY-MM" or "YYYY"; with "each photo's
    /// own" nothing goes, and each keeps its own year (and month).
    private func saveApprox() {
        var ch: [String: Any] = ["date_precision": known.apiName]
        if knownYear > 0 {
            ch["taken"] = known == .year ? String(format: "%04d", knownYear) : String(format: "%04d-%02d", knownYear, max(1, knownMonth))
        }
        save(ch, done: known == .year ? "Marked as year only." : "Marked as month and year.")
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: d)
    }

    private func save(_ ch: [String: Any], done: String? = nil) {
        Task {
            if await BulkEdit.apply(ids, ch, quiet: done != nil) {
                if let done { BulkToast.shared.show(done) }
                changed()
            }
        }
    }
}

// MARK: - templates

/// Apply one of the server's metadata templates (creator, copyright, contact...) to the selection.
struct BulkTemplateSheet: View {
    let ids: [Int]
    var changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var templates: [(name: String, fields: [String: String])]?
    @State private var fieldKeys: [String] = []

    static let labels = ["creator": "Creator", "copyrightNotice": "Copyright notice", "rightsUsageTerms": "Usage terms", "creatorJobTitle": "Job title",
                         "provider": "Credit", "source": "Source", "instructions": "Instructions", "creatorContactInfo.address": "Address",
                         "creatorContactInfo.city": "City", "creatorContactInfo.provinceState": "State / province", "creatorContactInfo.postalCode": "Postal code",
                         "creatorContactInfo.country": "Country", "creatorContactInfo.phone": "Phone", "creatorContactInfo.email": "Email", "creatorContactInfo.webUrl": "Web"]

    var body: some View {
        NavigationStack {
            List {
                if let templates {
                    if templates.isEmpty {
                        Text("No templates yet. Define them in Settings › Editing.").foregroundStyle(.secondary)
                    }
                    ForEach(templates, id: \.name) { t in
                        Button { Task { await apply(t.fields) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.headline).foregroundStyle(.primary)
                                Text(t.fields.filter { !$0.value.isEmpty }.map { "\(Self.labels[$0.key] ?? $0.key): \($0.value)" }.sorted().joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section { } footer: { Text("Applying a template sets every template field; fields left empty in the template are cleared on the photo, as in digiKam.") }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Apply a template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Cancel") } } }
            .task { await load() }
        }
    }

    private func load() async {
        guard let m = try? await IopixClient.shared.json("api/tools") else { templates = []; return }
        fieldKeys = m["templateFields"] as? [String] ?? Array(Self.labels.keys)
        templates = (m["templates"] as? [[String: Any]] ?? []).compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let fields = (t["fields"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            return (name, fields)
        }
    }

    private func apply(_ fields: [String: String]) async {
        var tpl: [String: String] = [:]
        for k in fieldKeys { tpl[k] = fields[k] ?? "" }
        if await BulkEdit.apply(ids, ["template": tpl]) { changed(); dismiss() }
    }
}

// MARK: - copy metadata

/// Copy chosen fields from one photo of the selection to the others.
struct BulkCopySheet: View {
    let ids: [Int]
    var changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source = 0
    @State private var fields: Set<String> = ["tags", "gps", "rights"]

    private static let all = [("rating", "Rating"), ("labels", "Pick and colour labels"), ("title", "Title"), ("caption", "Caption"),
                              ("tags", "Keywords (added)"), ("gps", "Location"), ("taken", "Date and time taken"), ("rights", "Creator and copyright")]

    var body: some View {
        NavigationStack {
            Form {
                Section("Copy from this photo") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(ids.prefix(60), id: \.self) { id in
                                Button { source = id } label: {
                                    RemoteImage(path: "thumb/\(id)").frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: source == id ? 3 : 0))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Section("What to copy") {
                    ForEach(Self.all, id: \.0) { k, label in
                        Toggle(label, isOn: Binding(get: { fields.contains(k) }, set: { if $0 { fields.insert(k) } else { fields.remove(k) } }))
                    }
                }
            }
            .navigationTitle("Copy to \(BulkEdit.plural(ids.count - 1, "photo"))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Cancel") } }
                ToolbarItem(placement: .confirmationAction) { Button { Task { await copy() } } label: { BarText("Copy") } }
            }
            .onAppear { if source == 0 { source = ids.first ?? 0 } }
        }
    }

    private func copy() async {
        guard let s = try? await IopixClient.shared.json("api/photo/\(source)") else { BulkToast.shared.show("Couldn't read that photo."); return }
        func str(_ k: String) -> String { s[k] as? String ?? "" }
        func int(_ k: String) -> Int { (s[k] as? NSNumber)?.intValue ?? 0 }
        var ch: [String: Any] = [:]
        if fields.contains("rating") { ch["rating"] = max(0, int("rating")) }
        if fields.contains("labels") { ch["pick"] = int("pick"); ch["color"] = int("color") }
        if fields.contains("title") { ch["title"] = str("title") }
        if fields.contains("caption") { ch["caption"] = str("caption") }  // what a person wrote; the AI description is not a caption
        if fields.contains("tags") {
            let t = (s["tags"] as? [[String: Any]] ?? []).filter { ($0["person"] as? NSNumber)?.boolValue != true }.compactMap { ($0["id"] as? NSNumber)?.intValue }
            if !t.isEmpty { ch["add_tags"] = t }
        }
        if fields.contains("gps"), let la = (s["lat"] as? NSNumber)?.doubleValue, let lo = (s["lon"] as? NSNumber)?.doubleValue {
            ch["gps"] = ["lat": la, "lon": lo, "alt": s["alt"] ?? NSNull()]
        }
        if fields.contains("taken"), let t = s["taken"] as? String, t.count >= 19 { ch["taken"] = String(t.prefix(19)) }
        if fields.contains("rights") {
            var tpl: [String: String] = [:]
            if !str("creator").isEmpty { tpl["creator"] = str("creator") }
            if !str("copyright").isEmpty { tpl["copyrightNotice"] = str("copyright") }
            if !tpl.isEmpty { ch["template"] = tpl }
        }
        let targets = ids.filter { $0 != source }
        guard !ch.isEmpty, !targets.isEmpty else { BulkToast.shared.show("Nothing to copy."); return }
        if await BulkEdit.apply(targets, ch, quiet: true) {
            BulkToast.shared.show("Copied to \(BulkEdit.plural(targets.count, "photo")). Each change is in the edit log with Undo.")
            changed(); dismiss()
        }
    }
}

// MARK: - location

/// Put the selection at one place: search an address, tap the map, use a nearby photo's position, or type it. The
/// ground height follows the pin until typed; "only the town is known" saves an approximate position.
struct BulkLocationSheet: View {
    let ids: [Int]
    var changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var lat = ""
    @State private var lon = ""
    @State private var alt = ""
    @State private var altNote: String?
    @State private var altTyped = false
    @State private var autoAlt = ""  // the last altitude the app filled in itself, to tell a typed one apart
    @State private var search = ""
    @State private var results: [(name: String, detail: String?, lat: Double, lon: Double)] = []
    @State private var resultNote: String?
    @State private var suggestions: [(id: Int, place: String, label: String, lat: Double, lon: Double, alt: Double?)]?
    @State private var landmarks = false
    @State private var townOnly = false
    @State private var accuracy = 2000.0
    @State private var camera: MapCameraPosition = .automatic
    @State private var confirmRemove = false

    private var pin: CLLocationCoordinate2D? {
        guard let la = Double(lat), let lo = Double(lon), abs(la) <= 90, abs(lo) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: la, longitude: lo)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Search an address or place", text: $search).onSubmit { Task { await find() } }
                    ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                        Button { place(r.lat, r.lon, zoomTo: 0.01); results = [] } label: {
                            VStack(alignment: .leading) {
                                Text(r.name).foregroundStyle(.primary)
                                if let d = r.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if let n = resultNote { Text(n).font(.caption).foregroundStyle(.secondary) }
                    Button { Task { await suggest() } } label: { Label("Suggest from photos taken around the same time", systemImage: "sparkles") }
                    if let suggestions {
                        if suggestions.isEmpty { Text("No photo with a location was taken within 6 hours of the first one.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(suggestions, id: \.id) { s in
                            Button { place(s.lat, s.lon, zoomTo: 0.005); if let a = s.alt { autoAlt = String(format: "%.1f", a); alt = autoAlt; altTyped = true; altNote = "altitude from that photo" } } label: {
                                HStack {
                                    RemoteImage(path: "thumb/\(s.id)").frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 5))
                                    VStack(alignment: .leading) {
                                        Text(s.place).foregroundStyle(.primary)
                                        Text(s.label).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if landmarks {
                            Button { Task { await landmark() } } label: { Label("Recognise a landmark in the photo (Google Cloud Vision)", systemImage: "building.columns") }
                        }
                    }
                }
                Section {
                    MapReader { proxy in
                        Map(position: $camera) {
                            if let pin {
                                Marker("", coordinate: pin)
                                if townOnly { MapCircle(center: pin, radius: accuracy).foregroundStyle(.orange.opacity(0.15)).stroke(.orange, lineWidth: 1) }
                            }
                        }
                        .onTapGesture { p in
                            if let c = proxy.convert(p, from: .local) { place(c.latitude, c.longitude, zoomTo: nil) }
                        }
                    }
                    .frame(height: 280)
                    .listRowInsets(EdgeInsets())
                } footer: { Text("Tap the map to put the pin there.") }
                Section("Position") {
                    TextField("Latitude", text: $lat).keyboardType(.numbersAndPunctuation).onSubmit { Task { await fetchAltitude() } }
                    TextField("Longitude", text: $lon).keyboardType(.numbersAndPunctuation).onSubmit { Task { await fetchAltitude() } }
                    if !townOnly {
                        TextField("Altitude (metres)", text: $alt).keyboardType(.numbersAndPunctuation)
                            .onChange(of: alt) { _, v in
                                if v != autoAlt { altTyped = !v.isEmpty; if altTyped { altNote = nil } }  // typed: the pin no longer sets it
                            }
                        if let altNote { Text(altNote).font(.caption).foregroundStyle(.secondary) }
                    }
                    Toggle("Only the town is known", isOn: $townOnly)
                    if townOnly {
                        Picker("Within about", selection: $accuracy) {
                            ForEach([500.0, 1000, 2000, 5000, 10000, 25000, 50000], id: \.self) { v in
                                Text(v >= 1000 ? "\(Int(v / 1000)) km" : "\(Int(v)) m").tag(v)
                            }
                        }
                    }
                }
                Section {
                    Button("Remove the location", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text(ids.count > 1 ? "The same position goes to all \(ids.count.formatted()) photos, replacing any they already have." : "")
                }
            }
            .navigationTitle(ids.count > 1 ? "Location for \(ids.count.formatted()) photos" : "Set location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Cancel") } }
                ToolbarItem(placement: .confirmationAction) { Button { Task { await save() } } label: { BarText("Save") }.disabled(pin == nil) }
            }
            .confirmationDialog("Remove the location from \(BulkEdit.plural(ids.count, "photo"))?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { Task { if await BulkEdit.apply(ids, ["gps": NSNull()]) { changed(); dismiss() } } }
            }
        }
    }

    private func place(_ la: Double, _ lo: Double, zoomTo span: Double?) {
        lat = String(format: "%.6f", la)
        lon = String(format: "%.6f", lo)
        if let span {
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: la, longitude: lo), span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
        }
        Task { await fetchAltitude() }
    }

    /// The ground height at the pin, until an altitude is typed or taken from a photo.
    private func fetchAltitude() async {
        guard !townOnly, !altTyped, let p = pin else { return }
        guard let r = try? await IopixClient.shared.json("api/elevation", query: [URLQueryItem(name: "lat", value: lat), URLQueryItem(name: "lon", value: lon)]) else {
            altNote = "no altitude service reachable"; return
        }
        guard pin?.latitude == p.latitude else { return }
        if let a = (r["alt"] as? NSNumber)?.doubleValue { autoAlt = String(format: "%.1f", a); alt = autoAlt }
        altNote = (r["source"] as? String).map { "ground height from \($0)" }
    }

    private func find() async {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        do {
            results = try await AppleSearch.places(q).map { ($0.name, $0.detail.isEmpty ? nil : $0.detail, $0.lat, $0.lon) }
            resultNote = results.isEmpty ? "Nothing found." : nil
        } catch { results = []; resultNote = AppleSearch.message(error) }
    }

    private func suggest() async {
        guard let first = ids.first, let r = try? await IopixClient.shared.json("api/location/suggest", query: [URLQueryItem(name: "id", value: String(first))]) else {
            suggestions = []; return
        }
        landmarks = r["landmarks"] as? Bool ?? false
        suggestions = (r["suggestions"] as? [[String: Any]] ?? []).compactMap { x in
            guard let id = (x["id"] as? NSNumber)?.intValue, let la = (x["lat"] as? NSNumber)?.doubleValue, let lo = (x["lon"] as? NSNumber)?.doubleValue else { return nil }
            let m = (x["minutes"] as? NSNumber)?.intValue ?? 0
            let a = abs(m)
            let t = a < 60 ? "\(a) min" : a < 1440 ? String(format: "%.1f h", Double(a) / 60) : String(format: "%.1f days", Double(a) / 1440)
            let when = m == 0 ? "same time" : m < 0 ? "\(t) before" : "\(t) after"
            let place = (x["place"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(format: "%.4f, %.4f", la, lo)
            let label = "\(x["name"] as? String ?? ""), taken \(when)" + ((x["same_camera"] as? Bool ?? true) ? "" : " (another camera)")
            return (id, place, label, la, lo, (x["alt"] as? NSNumber)?.doubleValue)
        }
    }

    private func landmark() async {
        guard let first = ids.first else { return }
        do {
            let r = try await BulkAPI.post("api/location/landmark", ["id": first])
            let found = (r["landmarks"] as? [[String: Any]] ?? []).compactMap { x -> (Int, String, String, Double, Double, Double?)? in
                guard let la = (x["lat"] as? NSNumber)?.doubleValue, let lo = (x["lon"] as? NSNumber)?.doubleValue else { return nil }
                let score = Int(((x["score"] as? NSNumber)?.doubleValue ?? 0) * 100)
                return (first, x["name"] as? String ?? "Landmark", "landmark, \(score)% sure", la, lo, nil)
            }
            landmarks = false
            if found.isEmpty { BulkToast.shared.show("Google recognized no landmark in this photo.") }
            suggestions = found.map { (id: $0.0, place: $0.1, label: $0.2, lat: $0.3, lon: $0.4, alt: $0.5) } + (suggestions ?? [])
        } catch { BulkToast.shared.show(error.localizedDescription) }
    }

    private func save() async {
        guard let p = pin else { BulkToast.shared.show("Enter a valid latitude and longitude."); return }
        var gps: [String: Any] = ["lat": p.latitude, "lon": p.longitude]
        if townOnly { gps["alt"] = NSNull(); gps["accuracy"] = accuracy }
        else { gps["alt"] = Double(alt.replacingOccurrences(of: ",", with: ".")) ?? NSNull() }
        if await BulkEdit.apply(ids, ["gps": gps]) { changed(); dismiss() }
    }
}

// MARK: - GPS track

/// Give each photo the position a GPX track recorded when it was taken (like digiKam's Geolocation Editor).
struct BulkGPXSheet: View {
    let ids: [Int]
    var changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var picking = false
    @State private var offset = TimeZone.current.secondsFromGMT()
    @State private var shift = 0
    @State private var shiftUnit = 60
    @State private var gap = 600
    @State private var onlyMissing = true
    @State private var result: [String: Any]?
    @State private var problem: String?
    @State private var busy = false

    private var zones: [Int] {
        var z = (0..<27).map { ($0 - 12) * 3600 } + [-9.5, -3.5, 3.5, 4.5, 5.5, 5.75, 6.5, 8.75, 9.5, 10.5, 12.75].map { Int($0 * 3600) }
        if !z.contains(offset) { z.append(offset) }
        return z.sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(file?.lastPathComponent ?? "Choose a .gpx file…") { picking = true }
                } footer: { Text("Track times are UTC; tell it what time zone the camera clock was set to.") }
                Section {
                    Picker("Camera's time zone", selection: $offset) { ForEach(zones, id: \.self) { Text(Self.zoneLabel($0)).tag($0) } }
                    Stepper("Clock error: \(shift)", value: $shift, in: -9999...9999)
                    Picker("Unit", selection: $shiftUnit) { Text("minutes").tag(60); Text("seconds").tag(1); Text("hours").tag(3600) }
                    Picker("Largest gap", selection: $gap) {
                        Text("2 minutes").tag(120); Text("10 minutes").tag(600); Text("30 minutes").tag(1800); Text("1 hour").tag(3600); Text("6 hours").tag(21600)
                    }
                    Toggle("Only photos without a position", isOn: $onlyMissing)
                } footer: { Text("A negative clock error if the camera ran fast.") }
                Section {
                    Button(busy ? "Matching…" : "Match") { Task { await match() } }.disabled(file == nil || busy)
                    if let r = result {
                        let track = r["track"] as? [String: Any] ?? [:]
                        let matched = (r["matched"] as? NSNumber)?.intValue ?? 0
                        let considered = (r["considered"] as? NSNumber)?.intValue ?? 0
                        Text("Track: \(((track["points"] as? NSNumber)?.intValue ?? 0).formatted()) points, \(String(format: "%.1f", (track["km"] as? NSNumber)?.doubleValue ?? 0)) km.")
                        Text("\(matched.formatted()) of \(considered.formatted()) photos match.").bold()
                        if let s = (r["skipped_with_position"] as? NSNumber)?.intValue, s > 0 { Text("\(s.formatted()) already had a position and were left alone.").foregroundStyle(.secondary) }
                    }
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Match with a GPS track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Cancel") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await apply() } } label: { BarText("Apply") }.disabled(((result?["matched"] as? NSNumber)?.intValue ?? 0) == 0 || busy)
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml]) { r in
                if case .success(let url) = r { file = url; Task { await match() } }
            }
        }
    }

    static func zoneLabel(_ s: Int) -> String {
        let a = abs(s), m = (a % 3600) / 60
        return "UTC\(s < 0 ? "-" : "+")\(a / 3600)" + (m > 0 ? String(format: ":%02d", m) : "")
    }

    private var params: [String: Any] { ["utc_offset": offset, "clock_shift": shift * shiftUnit, "max_gap": gap, "only_missing": onlyMissing] }

    private func match() async {
        guard let file else { return }
        busy = true
        defer { busy = false }
        problem = nil
        let opened = file.startAccessingSecurityScopedResource()
        defer { if opened { file.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: file) else { problem = "Couldn't read that file."; return }
        let boundary = "iopix-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("ids", ids.map(String.init).joined(separator: ","))
        field("utc_offset", String(offset)); field("clock_shift", String(shift * shiftUnit))
        field("max_gap", String(gap)); field("only_missing", onlyMissing ? "1" : "0")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"track.gpx\"\r\nContent-Type: application/gpx+xml\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var r = IopixClient.shared.request("api/gpx/preview", method: "POST")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        do {
            let (d, resp) = try await IopixClient.shared.session.upload(for: r, from: body)
            result = try IopixClient.shared.check(d, resp)
        } catch { problem = error.localizedDescription }
    }

    private func apply() async {
        guard let token = result?["token"] as? String else { return }
        busy = true
        defer { busy = false }
        do {
            var b = params
            b["token"] = token
            b["ids"] = ids
            let r = try await BulkAPI.post("api/gpx/apply", b)
            BulkToast.shared.show("Positions written to \(((r["edited"] as? NSNumber)?.intValue ?? 0).formatted()) photos.")
            changed(); dismiss()
        } catch { problem = error.localizedDescription }
    }
}

// MARK: - zip download

/// Download photos as zip files (resized, converted, renamed or without location if wanted), saved through the
/// share sheet (Save to Files).
struct BulkDownloadSheet: View {
    let query: PhotoQuery
    var title = "photos"
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exp-size") private var size = 0
    @AppStorage("exp-fmt") private var format = "keep"
    @AppStorage("exp-name") private var naming = "keep"
    @AppStorage("exp-nogps") private var noGPS = false
    @AppStorage("exp-flat") private var flat = false
    @State private var sidecars = false
    @State private var partMB = 2000
    @State private var plan: (files: Int, bytes: Int64, parts: [(first: String, last: String, files: Int, bytes: Int64)])?
    @State private var problem: String?
    @State private var downloading: Int?
    @State private var saved: [URL] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Size", selection: $size) {
                        Text("Original size").tag(0); Text("Large (4096 px)").tag(4096); Text("Medium (2048 px)").tag(2048); Text("Small (1280 px)").tag(1280)
                    }
                    Picker("Format", selection: $format) { Text("Same format").tag("keep"); Text("JPEG (HEIC, PNG and others converted)").tag("jpeg") }
                    Picker("File names", selection: $naming) {
                        Text("Their own names").tag("keep"); Text("Date and time").tag("date"); Text("Date and name").tag("date-name"); Text("Date and number").tag("date-seq")
                    }
                    Toggle("Remove the location from the copies", isOn: $noGPS)
                    Toggle("All files in one folder", isOn: $flat)
                    Toggle("Include digiKam sidecar files", isOn: $sidecars)
                    Picker("Zip files of at most", selection: $partMB) { Text("1 GB").tag(1000); Text("2 GB").tag(2000); Text("4 GB").tag(4000); Text("8 GB").tag(8000) }
                } footer: {
                    Text("Copies are made for the download; the photos in the library are not changed. Videos keep their size and format.")
                }
                Section {
                    if let plan {
                        if plan.files == 0 {
                            Text("Nothing to download.")
                        } else {
                            Text("\(plan.files.formatted()) \(plan.files == 1 ? "file" : "files"), \(ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)) as originals" +
                                 (plan.parts.count > 1 ? ", in \(plan.parts.count) zip files." : "."))
                            ForEach(Array(plan.parts.enumerated()), id: \.offset) { i, p in
                                Button { Task { await download(i) } } label: {
                                    HStack {
                                        Image(systemName: "arrow.down.circle")
                                        VStack(alignment: .leading) {
                                            Text(plan.parts.count == 1 ? "Download" : "Part \(i + 1)").foregroundStyle(.primary)
                                            Text("\(p.first == p.last ? p.first : "\(p.first) … \(p.last)")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        if downloading == i { ProgressView() } else {
                                            Text("\(p.files.formatted()) · \(ByteCountFormatter.string(fromByteCount: p.bytes, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .disabled(downloading != nil)
                            }
                        }
                    } else if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        ProgressView("Working out the download…")
                    }
                }
            }
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { BarText("Close") } } }
            .task(id: partMB) { await makePlan() }
            .sheet(isPresented: Binding(get: { !saved.isEmpty }, set: { if !$0 { clean() } })) { ShareSheet(items: saved) }
        }
    }

    private var base: [URLQueryItem] { query.filters }

    private func makePlan() async {
        plan = nil; problem = nil
        do {
            let req = BulkAPI.form("api/zip/plan", base + [URLQueryItem(name: "part_mb", value: String(partMB))])
            let (d, resp) = try await IopixClient.shared.session.data(for: req)
            let r = try IopixClient.shared.check(d, resp)
            plan = ((r["files"] as? NSNumber)?.intValue ?? 0, (r["bytes"] as? NSNumber)?.int64Value ?? 0,
                    (r["parts"] as? [[String: Any]] ?? []).map { p in
                        (p["first"] as? String ?? "", p["last"] as? String ?? "", (p["files"] as? NSNumber)?.intValue ?? 0, (p["bytes"] as? NSNumber)?.int64Value ?? 0)
                    })
        } catch { problem = error.localizedDescription }
    }

    private func download(_ part: Int) async {
        downloading = part
        defer { downloading = nil }
        var items = base + [URLQueryItem(name: "name", value: title), URLQueryItem(name: "part", value: String(part)),
                            URLQueryItem(name: "part_mb", value: String(partMB))]
        if sidecars { items.append(URLQueryItem(name: "sidecars", value: "1")) }
        if size > 0 { items.append(URLQueryItem(name: "xsize", value: String(size))) }
        if format != "keep" { items.append(URLQueryItem(name: "xfmt", value: format)) }
        if naming != "keep" { items.append(URLQueryItem(name: "xname", value: naming)) }
        if noGPS { items.append(URLQueryItem(name: "nogps", value: "1")) }
        if flat { items.append(URLQueryItem(name: "flat", value: "1")) }
        do {
            let (tmp, resp) = try await IopixClient.shared.session.download(for: BulkAPI.form("api/zip", items))
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let msg = (try? Data(contentsOf: tmp)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["detail"] as? String
                problem = msg ?? "The server didn't send the zip."
                return
            }
            let name = PhotoPager.filename(http) ?? "iopix-\(part + 1).zip"
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent(name)
            try FileManager.default.moveItem(at: tmp, to: dst)
            saved = [dst]
        } catch { problem = error.localizedDescription }
    }

    private func clean() {
        if let f = saved.first { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        saved = []
    }
}
