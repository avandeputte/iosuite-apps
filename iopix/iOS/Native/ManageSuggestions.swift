import SwiftUI

/// The suggestion pages the web keeps under Tools (iopix 1.94 and later): Place suggestions, Jersey
/// numbers, Clothing matches and Wrongly rotated. Nothing is written until a suggestion is used, and each use is in
/// the edit log with undo.

private func num(_ x: [String: Any], _ k: String) -> Double? { (x[k] as? NSNumber)?.doubleValue }
private func int(_ x: [String: Any], _ k: String) -> Int? { (x[k] as? NSNumber)?.intValue }

/// The coverage line under a page's intro while its analysis is still running ([done, total]).
private func coverage(_ j: [String: Any]) -> (Int, Int) {
    let c = (j["coverage"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
    return c.count == 2 ? (c[0], c[1]) : (0, 0)
}

/// A suggestion's row: its thumbnail (opening the viewer), its lines and its buttons.
private struct SuggestionRow<Lines: View, Buttons: View>: View {
    let id: Int
    var turn: Double = 0
    let open: () -> Void
    @ViewBuilder var lines: () -> Lines
    @ViewBuilder var buttons: () -> Buttons
    @AppStorage(ManageThumbSize.key) private var thumbSize = "list"

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: open) {
                let side = max(72, ManageThumbSize.side(thumbSize))
                RemoteImage(path: "thumb/\(id)")
                    .frame(width: turn == 0 ? side * 4 / 3 : side, height: side)
                    .rotationEffect(.degrees(turn))
                    .frame(width: side * 4 / 3, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                lines()
                HStack(spacing: 8) { buttons() }.padding(.top, 2)
            }
        }
    }
}

// MARK: - Place suggestions

struct PlaceSuggestion: Identifiable, Hashable {
    let id: Int, lat: Double, lon: Double, km: Double
    let place: String, text: String

    init?(json x: [String: Any]) {
        guard let id = int(x, "id"), let lat = num(x, "lat"), let lon = num(x, "lon") else { return nil }
        self.id = id; self.lat = lat; self.lon = lon; km = num(x, "km") ?? 1
        place = [x["place"], x["region"], x["country"]].compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: ", ")
        text = x["text"] as? String ?? ""
    }

    var whereText: String { place.isEmpty ? String(format: "%.4f, %.4f", lat, lon) : place }
    var within: String { km < 1 ? "within \(Int((km * 1000).rounded())) m" : String(format: "within %.1f km", km) }
}

/// Where each photo without a position was probably taken, from the photos around it that have one.
struct ManagePlaceSuggestScreen: View {
    @StateObject private var rights = ManageRights()
    @State private var items: [PlaceSuggestion] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var busy = false
    @State private var viewer: PagerStart?
    @State private var notice: Notice?
    @State private var confirmClose = false

    private var close: [PlaceSuggestion] { items.filter { $0.km <= 0.5 } }

    var body: some View {
        List {
            Section {
                Text("Where each photo without a position was probably taken, from the photos around it that have one: between two taken shortly before and after, the one nearest in time, the places photographed that day, or a stay with positions the day before and after. Each suggestion says how far off it may be. Nothing is saved until you use one: it is then saved as an approximate position, with undo in the edit log.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let problem { Text(problem).foregroundStyle(.secondary) }
            }
            Section {
                if loaded && items.isEmpty {
                    Text("No suggestions: no photo without a position has photos with one around it.").foregroundStyle(.secondary)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, x in
                    SuggestionRow(id: x.id, open: { viewer = PagerStart(list: PhotoList(ids: items.map(\.id)), index: i) }) {
                        (Text(x.whereText).bold() + Text("  (\(x.within))").foregroundStyle(.secondary))
                        if !x.text.isEmpty { Text(x.text).font(.caption).foregroundStyle(.secondary) }
                    } buttons: {
                        if rights.canWrite {
                            Button("Use") { Task { await use([x]) } }.buttonStyle(.bordered).controlSize(.small).disabled(busy)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Photos \(items.count.formatted())")
                    Spacer()
                    if rights.canWrite && !close.isEmpty {
                        Button("Use the \(close.count) closest") { confirmClose = true }.font(.caption).disabled(busy)
                    }
                }
            }
        }
        .navigationTitle("Place suggestions")
        .toolbar { ManageThumbSizeMenu() }
        .task { await rights.load(); if !loaded { await load() } }
        .refreshable { await load() }
        .pager($viewer)
        .notice($notice)
        .confirmationDialog("Use the suggested position for the \(close.count) \(close.count == 1 ? "photo" : "photos") placed within 500 m?",
                            isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Use them") { Task { await use(close) } }
        } message: { Text("Each is saved as an approximate position, with undo in the edit log.") }
    }

    private func load() async {
        do {
            let j = try await ManageAPI.get("api/placesuggest", [URLQueryItem(name: "limit", value: "1000")])
            items = (j["items"] as? [[String: Any]] ?? []).compactMap(PlaceSuggestion.init(json:))
            problem = nil
        } catch let e as URLError where e.code == .cancelled {
            return
        } catch is CancellationError {
            return
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    private func use(_ list: [PlaceSuggestion]) async {
        busy = true
        defer { busy = false }
        var done: Set<Int> = []
        do {
            for x in list {
                _ = try await EditAPI.post("api/edit", ["ids": [x.id], "changes": ["gps": ["lat": x.lat, "lon": x.lon, "accuracy": Int((x.km * 1000).rounded())]]])
                done.insert(x.id)
            }
            notice = Notice(text: list.count == 1 ? "Position saved." : "Saved \(list.count) positions.")
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
        items.removeAll { done.contains($0.id) }
        if !done.isEmpty { NotificationCenter.default.post(name: .iopixPhotosChanged, object: nil) }
    }
}

// MARK: - Jersey numbers and clothing matches

/// A person suggested for a photo where their face is not named: from a shirt number, or from what they wear.
struct PersonSuggestion: Identifiable, Hashable {
    let photo: Int, tag: Int, name: String
    let headline: String, detail: String
    var id: String { "\(photo)-\(tag)" }

    init?(json x: [String: Any], kind: ManagePersonSuggestScreen.Kind) {
        guard let p = int(x, "id"), let t = int(x, "tag") else { return nil }
        photo = p; tag = t; name = x["name"] as? String ?? "?"
        switch kind {
        case .jersey:
            let n = x["number"].map { "\($0)" } ?? "?"
            let count = int(x, "n") ?? 0
            headline = "Number \(n)"
            detail = x["basis"] as? String == "folder" ? "\(count) named in this folder" : "\(count) named this year"
        case .clothing:
            headline = x["event"] as? String ?? ""
            detail = [num(x, "score").map { "\(Int(($0 * 100).rounded()))%" }, x["text"] as? String].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// Jersey numbers or Clothing matches: one section per person, with Tag all, and Tag and Not them on each photo.
struct ManagePersonSuggestScreen: View {
    enum Kind: String { case jersey, clothing }
    let kind: Kind

    struct Player: Identifiable, Hashable { let id: Int, name: String, numbers: [String] }
    struct Group: Identifiable { let id: Int, name: String; var items: [PersonSuggestion] }

    @StateObject private var rights = ManageRights()
    @State private var items: [PersonSuggestion] = []
    @State private var players: [Player] = []
    @State private var ready = true
    @State private var cover = (0, 0)
    @State private var counts = (read: 0, named: 0)
    @State private var loaded = false
    @State private var problem: String?
    @State private var busy = false
    @State private var viewer: PagerStart?
    @State private var notice: Notice?
    @State private var tagAll: Group?

    private var title: String { kind == .jersey ? "Jersey numbers" : "Clothing matches" }
    private var endpoint: String { kind == .jersey ? "api/jerseys" : "api/clothing" }

    private var groups: [Group] {
        var out: [Group] = []
        var at: [Int: Int] = [:]
        for x in items {
            if let i = at[x.tag] { out[i].items.append(x) } else { at[x.tag] = out.count; out.append(Group(id: x.tag, name: x.name, items: [x])) }
        }
        return out
    }

    private var intro: String {
        kind == .jersey
            ? "The number on each detected person's shirt is read. Where a named face wears a number, that player is learnt for the folder and the year; a number on someone whose face is not named, seen from behind or too small for a face, then suggests the player. Tagging adds the person to the photo without a face region, with undo in the edit log; nothing is tagged until you do. \(counts.read.formatted()) numbers read, \(counts.named.formatted()) on named people."
            : "At an event everyone wears the same clothes all day. Within the photos of one folder on one day, each detected person whose face is not named (from behind, too far, too small) is compared with the people whose face is named, and a clear match suggests that person is in the photo too. Tagging adds the person to the photo without a face region, with undo in the edit log; nothing is tagged until you do."
    }

    private var waiting: String? {
        if !ready {
            return kind == .jersey
                ? "Install text recognition (RapidOCR) and an object detection model under Settings › AI to read jersey numbers."
                : "Install a content-search model and an object detection model under Settings › AI to match people by their clothes."
        }
        guard cover.0 < cover.1 else { return nil }
        return kind == .jersey
            ? "Reading numbers: \(cover.0.formatted()) of \(cover.1.formatted()) photos with people so far."
            : "Looking at the people: \(cover.0.formatted()) of \(cover.1.formatted()) photos so far."
    }

    var body: some View {
        List {
            Section {
                Text(intro).font(.footnote).foregroundStyle(.secondary)
                if let waiting { Label(waiting, systemImage: ready ? "hourglass" : "arrow.down.circle").font(.footnote) }
                if let problem { Text(problem).foregroundStyle(.secondary) }
            }
            if !players.isEmpty {
                Section("Players and their numbers") {
                    ForEach(players) { p in
                        HStack(spacing: 12) {
                            RemoteImage(path: "face/\(p.id)").frame(width: 36, height: 36).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.name).font(.body.weight(.semibold))
                                HStack(spacing: 10) {
                                    ForEach(p.numbers, id: \.self) { n in
                                        NavigationLink("Number \(n)", value: Screen.photos(PhotoQuery([("jersey", n)]), title: "Jersey number \(n)"))
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if loaded && items.isEmpty {
                Section {
                    Text(!ready ? "No suggestions yet." : kind == .jersey
                         ? "No suggestions: every number read is on a named person, or belongs to nobody known in that folder or year."
                         : "No suggestions: nobody dressed like a named person stands unnamed in the same event.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(groups) { g in
                Section {
                    ForEach(g.items) { x in
                        SuggestionRow(id: x.photo, open: { open(x, in: g) }) {
                            Text(x.headline).bold()
                            if !x.detail.isEmpty { Text(x.detail).font(.caption).foregroundStyle(.secondary) }
                        } buttons: {
                            if rights.canWrite {
                                Button("Tag") { Task { await tag([x]) } }.buttonStyle(.bordered).controlSize(.small).disabled(busy)
                                Button("Not them") { Task { await dismiss(x) } }.buttonStyle(.bordered).controlSize(.small).disabled(busy)
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        RemoteImage(path: "face/\(g.id)").frame(width: 22, height: 22).clipShape(Circle())
                        Text("\(g.name) \(g.items.count.formatted())")
                        Spacer()
                        if rights.canWrite && g.items.count >= 2 {
                            Button("Tag all") { tagAll = g }.font(.caption).disabled(busy)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .toolbar { ManageThumbSizeMenu() }
        .task { await rights.load(); if !loaded { await load() } }
        .refreshable { await load() }
        .pager($viewer)
        .notice($notice)
        .confirmationDialog(tagAll.map { "Tag \($0.name) on these \($0.items.count) photos?" } ?? "",
                            isPresented: Binding(get: { tagAll != nil }, set: { if !$0 { tagAll = nil } }), titleVisibility: .visible) {
            Button("Tag them") { if let g = tagAll { Task { await tag(g.items) } } }
        } message: { Text("Each is in the edit log with undo.") }
    }

    private func open(_ x: PersonSuggestion, in g: Group) {
        let ids = g.items.map(\.photo)
        viewer = PagerStart(list: PhotoList(ids: ids), index: ids.firstIndex(of: x.photo) ?? 0)
    }

    private func load() async {
        do {
            let j = try await ManageAPI.get(endpoint, [URLQueryItem(name: "limit", value: "2000")])
            items = (j["items"] as? [[String: Any]] ?? []).compactMap { PersonSuggestion(json: $0, kind: kind) }
            players = (j["players"] as? [[String: Any]] ?? []).compactMap { p in
                guard let t = int(p, "tag") else { return nil }
                return Player(id: t, name: p["name"] as? String ?? "?", numbers: (p["numbers"] as? [Any] ?? []).map { "\($0)" })
            }
            ready = (j["ready"] as? Bool) ?? true
            cover = coverage(j)
            counts = (int(j, "read") ?? 0, int(j, "named") ?? 0)
            problem = nil
        } catch let e as URLError where e.code == .cancelled {
            return
        } catch is CancellationError {
            return
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    private func tag(_ list: [PersonSuggestion]) async {
        busy = true
        defer { busy = false }
        do {
            try await EditAPI.faceOps(list.map { ["op": "tagonly", "image": $0.photo, "tag": $0.tag] })
            let gone = Set(list.map(\.id))
            items.removeAll { gone.contains($0.id) }
            notice = Notice(text: list.count == 1 ? "Added \(list[0].name)." : "\(list.count) photos tagged.")
            NotificationCenter.default.post(name: .iopixPhotosChanged, object: nil)
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }

    private func dismiss(_ x: PersonSuggestion) async {
        do {
            _ = try await ManageAPI.post("api/suggestions/dismiss", ["kind": kind.rawValue, "pairs": [[x.photo, x.tag]]])
            items.removeAll { $0.id == x.id }
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }
}

// MARK: - Wrongly rotated

struct RotationFinding: Identifiable, Hashable {
    let id: Int, op: String, text: String, score: Double

    init?(json x: [String: Any]) {
        guard let id = int(x, "id"), let op = x["op"] as? String else { return nil }
        self.id = id; self.op = op; text = x["text"] as? String ?? ""; score = num(x, "score") ?? 0
    }

    /// How the thumbnail is turned to show the photo the way the fix would leave it.
    var turn: Double { op == "left" ? -90 : op == "right" ? 90 : op == "180" ? 180 : 0 }
    var label: String { op == "left" ? "Rotate left" : op == "right" ? "Rotate right" : op == "180" ? "Turn upside down" : "Rotate" }
}

/// Photos stored on their side or upside down, each shown the way it would look after the lossless turn.
struct ManageRotationScreen: View {
    @StateObject private var rights = ManageRights()
    @State private var items: [RotationFinding] = []
    @State private var dismissed = 0
    @State private var ready = true
    @State private var running = false
    @State private var phase: String?
    @State private var cover = (0, 0)
    @State private var lossless = true
    @State private var loaded = false
    @State private var problem: String?
    @State private var busy = false
    @State private var viewer: PagerStart?
    @State private var notice: Notice?
    @State private var confirmAll = false

    private var waiting: String? {
        if !ready { return "Install a content-search model under Settings › AI: the check learns what upright looks like from its embeddings of your own photos." }
        if running, let phase {
            let what = phase == "learning" ? "Learning what upright looks like from your photos" : phase == "checking" ? "Checking the photos that read as turned" : "Reading every photo"
            return "\(what): \(cover.0.formatted()) of \(cover.1.formatted()) so far."
        }
        if !lossless { return "Rotating needs jpegtran on the server (libjpeg-turbo); until then the list is only shown." }
        return nil
    }

    private var canRotate: Bool { rights.canWrite && lossless }

    var body: some View {
        List {
            Section {
                Text("Photos stored on their side or upside down, usually scans and old files. Your own photos teach the content-search model what upright looks like; every photo whose embedding reads as turned is then checked in all four turns, and only the ones the four readings agree on are listed, each shown the way it would look after the turn. Rotating is the lossless rotate (the file is turned, the metadata kept, undo in the edit log); nothing is changed until you do.\(dismissed > 0 ? " \(dismissed.formatted()) marked as fine are left out." : "")")
                    .font(.footnote).foregroundStyle(.secondary)
                if let waiting { Label(waiting, systemImage: ready ? "hourglass" : "arrow.down.circle").font(.footnote) }
                if let problem { Text(problem).foregroundStyle(.secondary) }
            }
            Section {
                if loaded && items.isEmpty {
                    Text(ready ? "Nothing looks turned." : "Nothing checked yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, x in
                    SuggestionRow(id: x.id, turn: x.turn, open: { viewer = PagerStart(list: PhotoList(ids: items.map(\.id)), index: i) }) {
                        (Text(x.text).bold() + Text("  \(Int((x.score * 100).rounded()))%").foregroundStyle(.secondary))
                    } buttons: {
                        if canRotate {
                            Button(x.label) { Task { await rotate([x]) } }.buttonStyle(.bordered).controlSize(.small).disabled(busy)
                        }
                        if rights.canWrite {
                            Button("It's fine") { Task { await dismiss(x) } }.buttonStyle(.bordered).controlSize(.small).disabled(busy)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Photos \(items.count.formatted())")
                    Spacer()
                    if canRotate && items.count >= 2 {
                        Button("Rotate all \(items.count)") { confirmAll = true }.font(.caption).disabled(busy)
                    }
                }
            }
        }
        .navigationTitle("Wrongly rotated")
        .toolbar { ManageThumbSizeMenu() }
        .task { await rights.load(); if !loaded { await load() } }
        .refreshable { await load() }
        .pager($viewer)
        .notice($notice)
        .confirmationDialog("Rotate all \(items.count) photos the way shown?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Rotate them") { Task { await rotate(items) } }
        } message: { Text("Each turn is lossless and in the edit log with undo.") }
    }

    private func load() async {
        do {
            async let s = try? ManageAPI.get("api/status")
            let j = try await ManageAPI.get("api/rotation", [URLQueryItem(name: "limit", value: "1000")])
            items = (j["items"] as? [[String: Any]] ?? []).compactMap(RotationFinding.init(json:))
            dismissed = int(j, "dismissed") ?? 0
            ready = (j["ready"] as? Bool) ?? true
            running = (j["running"] as? Bool) ?? false
            phase = j["phase"] as? String
            cover = coverage(j)
            if let st = await s { lossless = (st["lossless"] as? [String: Any])?["jpegtran"] as? Bool ?? false }
            problem = nil
        } catch let e as URLError where e.code == .cancelled {
            return
        } catch is CancellationError {
            return
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    private func rotate(_ list: [RotationFinding]) async {
        busy = true
        defer { busy = false }
        var done: Set<Int> = []
        do {
            for (op, group) in Dictionary(grouping: list, by: \.op) {
                for chunk in stride(from: 0, to: group.count, by: 500).map({ Array(group[$0..<min($0 + 500, group.count)]) }) {
                    _ = try await EditAPI.post("api/photos/transform", ["ids": chunk.map(\.id), "op": op])
                    done.formUnion(chunk.map(\.id))
                }
            }
            notice = Notice(text: list.count == 1 ? "Rotated." : "Rotated \(list.count) photos.")
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
        items.removeAll { done.contains($0.id) }
        if !done.isEmpty {
            ImageCache.shared.removeAll()  // the thumbnails are turned too
            NotificationCenter.default.post(name: .iopixPhotosChanged, object: nil)
        }
    }

    private func dismiss(_ x: RotationFinding) async {
        do {
            _ = try await ManageAPI.post("api/rotation/dismiss", ["photos": [x.id]])
            items.removeAll { $0.id == x.id }
            dismissed += 1
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }
}
