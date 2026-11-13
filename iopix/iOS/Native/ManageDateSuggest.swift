import SwiftUI

/// A year for a photo marked "Date unknown", from how old the named people in it look (iopix 1.82). Nothing is
/// saved until a year is used: it is then a year-only date, with undo in the edit log.
struct DateSuggestion: Identifiable, Hashable {
    struct Who: Hashable { let tag: Int, name: String, age: Int }
    let id: Int, year: Int, lo: Int, hi: Int
    let people: [Who]
    /// What the year comes from (iopix 1.95): the people's ages, the years they are photographed in, look-alikes, the camera.
    let clues: [String]

    init?(json x: [String: Any]) {
        func int(_ k: String) -> Int? { (x[k] as? NSNumber)?.intValue }
        guard let id = int("id"), let year = int("year") else { return nil }
        self.id = id; self.year = year; lo = int("lo") ?? year; hi = int("hi") ?? year
        people = (x["people"] as? [[String: Any]] ?? []).compactMap { p in
            guard let t = (p["tag"] as? NSNumber)?.intValue, let n = p["name"] as? String else { return nil }
            return Who(tag: t, name: n, age: (p["age"] as? NSNumber)?.intValue ?? 0)
        }
        clues = (x["clues"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    }

    var range: String { lo == hi ? "" : "\(lo)–\(hi)" }
    var why: String {
        if !clues.isEmpty { return clues.joined(separator: " · ") }
        return "From how old \(people.count == 1 ? "this person looks" : "these people look"): " +
            people.map { "\($0.name) (looks about \($0.age))" }.joined(separator: ", ") + "."
    }

    /// Saves these photos' dates as their suggested years, year only.
    static func use(_ list: [DateSuggestion]) async throws {
        for (year, items) in Dictionary(grouping: list, by: \.year) {
            _ = try await EditAPI.post("api/edit", ["ids": items.map(\.id), "changes": ["date_precision": "year", "taken": String(format: "%04d", year)]])
        }
    }
}

/// Explore › Date suggestions on the web: the suggested years for every photo marked "Date unknown", and the people
/// they come from, whose birth years editors can enter.
struct ManageDateSuggestScreen: View {
    @AppStorage(ManageThumbSize.key) private var thumbSize = "list"
    struct Person: Identifiable, Hashable {
        let id: Int, name: String, birth: Int?, entered: Bool, basis: String?, n: Int
        var detail: String {
            let born = birth.map { "born \(entered ? "" : "about ")\($0)" } ?? "birth year unknown"
            let from = basis == "fit" ? "from \(n.formatted()) photos with a date" : basis == "dated" ? "from only \(n) photos with a date"
                : basis == "entered" ? "birth year you entered" : "too few photos with a date: enter a birth year"
            return "\(born) (\(from))"
        }
    }
    @StateObject private var rights = ManageRights()
    @State private var items: [DateSuggestion] = []
    @State private var people: [Person] = []
    /// The earliest and latest year anything in a folder (subfolders included) can be from (iopix 1.98).
    struct Hint: Identifiable {
        let id: Int, path: String, n: Int, notBefore: Int?, notAfter: Int?
        var detail: String {
            var parts: [String] = []
            if n > 0 { parts.append("\(n.formatted()) undated") }
            parts.append("not before \(notBefore.map(String.init) ?? "–")")
            parts.append("not after \(notAfter.map(String.init) ?? "–")")
            return parts.joined(separator: " · ")
        }
    }
    @State private var hints: [Hint] = []
    @State private var askingHint: Hint?
    @State private var hintBefore = ""
    @State private var hintAfter = ""
    @State private var ready = true
    @State private var faces = (0, 0)
    @State private var loaded = false
    @State private var problem: String?
    @State private var busy = false
    @State private var viewer: PagerStart?
    @State private var notice: Notice?
    @State private var askingBirth: Person?
    @State private var birthText = ""
    @State private var confirmClose = false

    private var close: [DateSuggestion] { items.filter { $0.hi - $0.lo <= 4 } }

    var body: some View {
        List {
            Section {
                Text("A year for each photo marked “Date unknown”, from every clue the library has about it: how old the named people in it look, the years those people are photographed in, the photos with a date that look most like it, and the camera. Every suggestion is a range and lists its clues. Nothing is saved until you use a year: it is then saved as a year-only date, with undo in the edit log.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !ready {
                    Label("Install “MiVOLO v2 (age)” under Settings › AI to get suggestions.", systemImage: "arrow.down.circle")
                        .font(.footnote)
                } else if faces.0 < faces.1 {
                    Label("Estimating ages: \(faces.0.formatted()) of \(faces.1.formatted()) faces so far; more suggestions appear as it goes.", systemImage: "hourglass")
                        .font(.footnote)
                }
                if let problem { Text(problem).foregroundStyle(.secondary) }
            }
            if !hints.isEmpty {
                Section {
                    ForEach(hints) { f in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.path.isEmpty ? "/" : f.path).font(.body.weight(.semibold))
                                Text(f.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if rights.canWrite {
                                Button("Edit") { hintBefore = f.notBefore.map(String.init) ?? ""; hintAfter = f.notAfter.map(String.init) ?? ""; askingHint = f }
                                    .buttonStyle(.borderless).font(.callout)
                            }
                        }
                    }
                } header: { Text("Folder hints") } footer: {
                    Text("The earliest and latest year anything in a folder can be from, subfolders included: every suggestion in it keeps to those years.")
                }
            }
            if !people.isEmpty {
                Section("People") {
                    ForEach(people) { p in
                        HStack(spacing: 12) {
                            RemoteImage(path: "face/\(p.id)").frame(width: 36, height: 36).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.body.weight(.semibold))
                                Text(p.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if rights.canWrite {
                                Button(p.entered ? "Change" : "Birth year") { birthText = p.entered ? p.birth.map(String.init) ?? "" : ""; askingBirth = p }
                                    .buttonStyle(.borderless).font(.callout)
                            }
                        }
                    }
                }
            }
            Section {
                if loaded && items.isEmpty {
                    Text(ready ? "No suggestions: no photo marked “Date unknown” has a clue to go on." : "No suggestions yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, x in
                    HStack(alignment: .top, spacing: 12) {
                        Button { viewer = PagerStart(list: PhotoList(ids: items.map(\.id)), index: i) } label: {
                            RemoteImage(path: "thumb/\(x.id)").frame(width: max(96, ManageThumbSize.side(thumbSize) * 4 / 3), height: max(72, ManageThumbSize.side(thumbSize))).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 3) {
                            (Text("About \(String(x.year))").bold() + Text(x.range.isEmpty ? "" : "  (\(x.range))").foregroundStyle(.secondary))
                            Text(x.clues.isEmpty ? x.people.map { "\($0.name) looks \($0.age)" }.joined(separator: " · ") : x.clues.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if rights.canWrite {
                                Button("Use \(String(x.year))") { Task { await use([x]) } }
                                    .buttonStyle(.bordered).controlSize(.small).disabled(busy)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Photos")
                    Spacer()
                    if rights.canWrite && !close.isEmpty {
                        Button("Use the \(close.count) closest") { confirmClose = true }.font(.caption).disabled(busy)
                    }
                }
            }
        }
        .navigationTitle("Date suggestions")
        .toolbar { ManageThumbSizeMenu() }
        .task { await rights.load(); if !loaded { await load() } }
        .onAppear { if !loaded { Task { await load() } } }
        .refreshable { await load() }
        .pager($viewer)
        .notice($notice)
        .confirmationDialog("Use the suggested year for the \(close.count) \(close.count == 1 ? "photo" : "photos") whose range is four years or less?",
                            isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Use them") { Task { await use(close) } }
        } message: { Text("Each is saved as a year-only date, with undo in the edit log.") }
        .alert(askingBirth.map { "\($0.name)’s year of birth" } ?? "", isPresented: Binding(get: { askingBirth != nil }, set: { if !$0 { askingBirth = nil } })) {
            TextField("e.g. 1942", text: $birthText).keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let p = askingBirth { Task { await setBirth(p) } } }
        } message: { Text("Leave it empty to work it out from photos with a date.") }
        .alert(askingHint.map { "Years for \($0.path.isEmpty ? "/" : $0.path)" } ?? "", isPresented: Binding(get: { askingHint != nil }, set: { if !$0 { askingHint = nil } })) {
            TextField("Not before (e.g. 1974)", text: $hintBefore).keyboardType(.numberPad)
            TextField("Not after (e.g. 1992)", text: $hintAfter).keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let f = askingHint { Task { await setHint(f) } } }
        } message: { Text("Leave a field empty for no bound.") }
    }

    private func setHint(_ f: Hint) async {
        do {
            try await ManageAPI.post("api/datehints", ["album": f.id, "not_before": Int(hintBefore.trimmingCharacters(in: .whitespaces)) ?? NSNull(),
                                                      "not_after": Int(hintAfter.trimmingCharacters(in: .whitespaces)) ?? NSNull()])
            notice = Notice(text: "Hint saved.")
            await load()
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }

    private func load() async {
        do {
            let j = try await ManageAPI.get("api/datesuggest", [URLQueryItem(name: "limit", value: "500")])
            items = (j["items"] as? [[String: Any]] ?? []).compactMap(DateSuggestion.init(json:))
            people = (j["people"] as? [[String: Any]] ?? []).compactMap { p in
                guard let t = (p["tag"] as? NSNumber)?.intValue, let n = p["name"] as? String else { return nil }
                return Person(id: t, name: n, birth: (p["birth"] as? NSNumber)?.intValue, entered: (p["entered"] as? Bool) ?? ((p["entered"] as? NSNumber)?.boolValue ?? false),
                              basis: p["basis"] as? String, n: (p["n"] as? NSNumber)?.intValue ?? 0)
            }
            if let h = try? await ManageAPI.get("api/datehints") {  // shown without, on an older iopix
                hints = (h["folders"] as? [[String: Any]] ?? []).compactMap { f in
                    guard let a = (f["album"] as? NSNumber)?.intValue else { return nil }
                    return Hint(id: a, path: f["path"] as? String ?? "", n: (f["n"] as? NSNumber)?.intValue ?? 0,
                                notBefore: (f["not_before"] as? NSNumber)?.intValue, notAfter: (f["not_after"] as? NSNumber)?.intValue)
                }
            }
            ready = (j["ready"] as? Bool) ?? true
            let f = (j["faces"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            faces = f.count == 2 ? (f[0], f[1]) : (0, 0)
            problem = nil
        } catch let e as URLError where e.code == .cancelled {
            return  // the screen went away mid-load (or is being shown again): the next appearance loads afresh
        } catch is CancellationError {
            return
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    private func use(_ list: [DateSuggestion]) async {
        busy = true
        defer { busy = false }
        do {
            try await DateSuggestion.use(list)
            let gone = Set(list.map(\.id))
            items.removeAll { gone.contains($0.id) }
            notice = Notice(text: list.count == 1 ? "Saved as \(list[0].year)." : "Saved \(list.count) photos as their suggested years.")
            NotificationCenter.default.post(name: .iopixPhotosChanged, object: nil)
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }

    private func setBirth(_ p: Person) async {
        let t = birthText.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, Int(t) == nil { notice = Notice(text: "The year has four digits.", failed: true); return }
        do {
            _ = try await ManageAPI.post("api/people/birth", ["tag": p.id, "year": Int(t) as Any? ?? NSNull()])
            await load()
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }
}
