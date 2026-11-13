import SwiftUI

/// Tools, for admins, as the web app's Tools page (#/tools): the checks, the suggestions and the library actions,
/// each check and suggestion page summarised in a line. The settings themselves are all under Settings.
struct AdminToolsScreen: View {
    @StateObject private var notice = AdminNotice()
    @State private var m: [String: Any] = [:]
    @State private var status: [String: Any] = [:]
    @State private var consistency: String?
    @State private var quality: String?
    @State private var damaged: String?
    @State private var duplicates: String?
    /// Each suggestion page's line ("12 suggestions (800 / 900 analysed)."), by its route.
    @State private var suggestions: [String: String] = [:]
    @State private var applying = false
    @State private var problem: String?

    private var appName: String { status.str("appName") ?? "ioPix" }
    private var editing: Bool { status.bool("editing") }

    var body: some View {
        List {
            if let problem, m.isEmpty {
                Section { Text(problem).foregroundStyle(.secondary) }
            }
            if !m.isEmpty {
                checks
                suggestionsSection
                library
            } else if problem == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Tools")
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $applying) { AdminApplyEditsSheet(appName: appName) { await load() } }
        .adminNotice(notice)
    }

    private var checks: some View {
        Section("Checks") {
            NavigationLink { AdminConsistencyScreen() } label: {
                AdminRow(title: "Metadata consistency", detail: (consistency ?? "") + "Rating, title, caption and tags in digiKam, the sidecars and the files.")
            }
            NavigationLink { ManageQualityScreen() } label: {
                AdminRow(title: "Metadata quality", detail: (quality ?? "") + "Missing locations, odd dates, duplicate faces and boxes outside the photo.")
            }
            NavigationLink { ManageDuplicatesScreen() } label: {
                AdminRow(title: "Duplicate files", detail: (duplicates ?? "") + "From digiKam’s fingerprints; remove the extras in digiKam.")
            }
            NavigationLink { AdminDamagedScreen(canEdit: editing) } label: {
                AdminRow(title: "Damaged files", detail: (damaged ?? "") + "Files that stop early or cannot be decoded, with a safe repair where there is one.")
            }
        }
    }

    private var suggestionsSection: some View {
        Section("Suggestions") {
            ForEach(Self.suggestionPages, id: \.route) { page in
                NavigationLink { page.screen() } label: {
                    AdminRow(title: page.title, detail: (suggestions[page.route] ?? "") + page.text)
                }
            }
            if editing {
                NavigationLink { AdminPlaceTagsScreen() } label: {
                    AdminRow(title: "Place tags", detail: "Places/Country/Region/Town tags from each photo’s GPS position.")
                }
            }
        }
    }

    @ViewBuilder private var library: some View {
        Section("Library") {
            VStack(alignment: .leading, spacing: 6) {
                AdminRow(title: "Rescan the library", detail: "The index is rebuilt whenever digiKam saves (last saved \(AdminFormat.when(m.dbl("digikamSaved"))), index built \(AdminFormat.when(m.dbl("indexBuilt")))).")
                Button("Rescan now") { action("reindex", "Rescanning the library…") }
            }
            if editing {
                let pending = m.int("pendingEdits") ?? 0
                VStack(alignment: .leading, spacing: 6) {
                    AdminRow(title: "Edits waiting for digiKam",
                             detail: pending > 0 ? "\(AdminFormat.plural(pending, "photo has", "photos have")) edits in sidecars that digiKam’s database does not have yet\(m.bool("digikamRunning") ? "; close digiKam to apply them" : "")."
                                : "None.")
                    if pending > 0 { Button("Apply to digiKam database…") { applying = true } }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                AdminRow(title: "Tag cover photos", detail: "Picked by the content model; pick again after big tagging changes.")
                Button("Pick again") { action("covers", "Choosing tag covers in the background.") }
            }
        }
    }

    /// The suggestion pages, summarised in a line each from a one-item read of their lists (the total comes with it).
    struct SuggestionPage {
        let route: String, title: String, text: String, noun: String
        let screen: () -> AnyView
    }
    static let suggestionPages = [
        SuggestionPage(route: "datesuggest", title: "Date suggestions", text: "A year for photos marked Date unknown.", noun: "suggestion") { AnyView(ManageDateSuggestScreen()) },
        SuggestionPage(route: "placesuggest", title: "Place suggestions", text: "A position for photos without one, from the photos around them.", noun: "suggestion") { AnyView(ManagePlaceSuggestScreen()) },
        SuggestionPage(route: "jerseys", title: "Jersey numbers", text: "Players read from shirt numbers.", noun: "suggestion") { AnyView(ManagePersonSuggestScreen(kind: .jersey)) },
        SuggestionPage(route: "clothing", title: "Clothing matches", text: "People recognised by what they wear at the same event.", noun: "suggestion") { AnyView(ManagePersonSuggestScreen(kind: .clothing)) },
        SuggestionPage(route: "rotation", title: "Wrongly rotated", text: "Photos on their side or upside down.", noun: "photo") { AnyView(ManageRotationScreen()) },
    ]

    private func action(_ a: String, _ done: String) {
        Task { await notice.run(done) { try await AdminAPI.post("api/tools", ["action": a]); try? await Task.sleep(nanoseconds: 1_500_000_000); await load() } }
    }

    private func load() async {
        do {
            async let a = AdminAPI.get("api/tools")
            async let b = AdminAPI.get("api/status")
            let got = try await a
            status = (try? await b) ?? status
            if got.dict("paths").isEmpty {  // the server leaves the paths out for everyone but admins
                m = [:]
                problem = "Tools are for admins."
                return
            }
            m = got
            problem = nil
        } catch {
            problem = "Couldn't load the tools: \(error.localizedDescription)"
            return
        }
        if let c = try? await AdminAPI.get("api/consistency", [URLQueryItem(name: "limit", value: "1")]) {
            let s = c.dict("summary"), p = c.dict("progress")
            consistency = p.bool("running") ? "Checking… \(AdminFormat.n(p.int("done"))) / \(AdminFormat.n(p.int("total"))) photos. "
                : (s.int("scanned") ?? 0) == 0 ? "Not checked yet. "
                : "\((s.int("mismatched") ?? 0) > 0 ? AdminFormat.plural(s.int("mismatched") ?? 0, "photo disagrees", "photos disagree") : "Everything agrees")\(s.dbl("scanned_at").map { " (checked \(AdminFormat.when($0)))" } ?? ""). "
        }
        if let q = try? await AdminAPI.get("api/quality") {
            var t = ""
            if let n = q.dict("near").int("extra"), n > 0 { t += "\(AdminFormat.plural(n, "face is", "faces are")) stored twice. " }
            if let n = q.dict("separate").int("count"), n > 0 { t += "\(AdminFormat.plural(n, "photo has", "photos have")) the same person twice. " }
            if let n = q.dict("unnamed").int("count"), n > 0 { t += "\(AdminFormat.plural(n, "photo has", "photos have")) faces but no names. " }
            if let n = q.dict("invalid").int("count"), n > 0 { t += "\(AdminFormat.plural(n, "box is", "boxes are")) outside the photo. " }
            quality = t
        }
        if let d = try? await AdminAPI.get("api/duplicates") {
            let sets = d.list("groups").count
            duplicates = sets > 0 ? "\(AdminFormat.plural(sets, "set")) of identical files, \(AdminFormat.bytes(d.dbl("wasted"))) that could be freed. " : "No identical copies. "
        }
        for page in Self.suggestionPages {
            guard let d = try? await AdminAPI.get("api/\(page.route)", [URLQueryItem(name: "limit", value: "1")]) else { continue }
            let total = d.int("total") ?? 0
            suggestions[page.route] = (d["ready"] as? Bool) == false ? "Not analysed yet. " : (total > 0 ? AdminFormat.plural(total, page.noun) : "No \(page.noun)s") + ". "
        }
        if let f = try? await AdminAPI.get("api/filecheck") {
            let p = f.dict("progress"), found = f.list("found")
            damaged = p.bool("running") ? "Checking… \(AdminFormat.n(p.int("done"))) / \(AdminFormat.n(p.int("total"))) files. "
                : (f.int("checked") ?? 0) == 0 ? "Not checked yet. "
                : !found.isEmpty ? "\(AdminFormat.plural(found.count, "damaged file")) (\(found.filter { $0.bool("fixable") }.count) repairable). "
                : "Nothing damaged. "
        }
    }
}

/// Tools › Place tags: each geotagged photo's town as real digiKam tags under Places/Country/Region/Town.
struct AdminPlaceTagsScreen: View {
    @StateObject private var notice = AdminNotice()
    @State private var placeTags: [String: Any]?
    @State private var poll: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                if let p = placeTags {
                    let prog = p.dict("progress")
                    Text("\(AdminFormat.n(p.int("to_tag"))) of \(AdminFormat.n(p.int("photos"))) geotagged photos would get a place tag they do not have yet.").font(.footnote)
                    if (p.int("to_untag") ?? 0) > 0 { Text("\(AdminFormat.n(p.int("to_untag"))) photos have a place tag from an earlier position, which would be removed.").font(.footnote) }
                    let missing = p.strings("missing_tags")
                    Text(missing.isEmpty ? "All the needed tags already exist." : "\(AdminFormat.n(missing.count)) new tags would be created under “\(p.str("root") ?? "Places")”, for example: \(missing.prefix(5).joined(separator: ", ")).").font(.footnote)
                    if !missing.isEmpty && p.bool("digikamRunning") { Text("digiKam is running. Quit it first; the new tags go into its database.").font(.footnote).foregroundStyle(.orange) }
                    if prog.bool("running") { AdminProgress(done: prog.int("done") ?? 0, total: prog.int("total") ?? 0, label: "Tagging") }
                    if let e = prog.str("error"), !e.isEmpty { Text(e).font(.footnote).foregroundStyle(.red) }
                    Button("Create and assign") {
                        Task {
                            await notice.run(nil) {
                                let r = try await AdminAPI.post("api/placetags", ["ids": [Int]()])
                                notice.say("Tagging \(AdminFormat.n(r.int("to_tag"))) photos\((r.int("creating") ?? 0) > 0 ? ", creating \(r.int("creating")!) tags" : "") in the background.")
                                poll?.cancel()
                                poll = Task { await pollPlaceTags() }
                            }
                        }
                    }
                    .disabled((p.int("to_tag") ?? 0) == 0 || prog.bool("running") || (!missing.isEmpty && p.bool("digikamRunning")))
                } else {
                    ProgressView()
                }
            } header: { Text("Place tags from GPS positions") } footer: {
                Text("Turns each geotagged photo's town into real digiKam tags under “Places/Country/Region/Town”, so places are searchable in digiKam too. Town names come from the offline place lookup and can be a neighboring town.")
            }
        }
        .navigationTitle("Place tags")
        .task { placeTags = try? await AdminAPI.get("api/placetags") }
        .onDisappear { poll?.cancel() }
        .adminNotice(notice)
    }

    private func pollPlaceTags() async {
        for _ in 0..<200 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }  // the screen is gone
            guard let p = try? await AdminAPI.get("api/placetags") else { return }
            placeTags = p
            if !p.dict("progress").bool("running") { return }
        }
    }
}

/// Edits saved in sidecars that digiKam's database doesn't have yet: write them in (digiKam closed).
struct AdminApplyEditsSheet: View {
    let appName: String
    let done: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: Router
    @State private var st: [String: Any]?
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                if let st {
                    Section {
                        Text("\(AdminFormat.plural(st.int("pending") ?? 0, "photo has", "photos have")) edits that are saved in XMP sidecars but not yet in digiKam's database.")
                        Text("This writes the same ratings, labels, titles, captions and tags into digiKam's database. A copy of the database is saved in \(appName)'s data/db-backups folder first.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(st.bool("digikamRunning") ? "digiKam is running. Quit digiKam first; its database must not be changed while it is open."
                             : st.bool("ask") ? "\(appName) cannot see from here whether digiKam is open, so it does not check." : "digiKam is closed, so its database can be updated now.")
                            .font(.footnote).foregroundStyle(st.bool("digikamRunning") ? .orange : .secondary)
                    }
                    if let problem { Text(problem).foregroundStyle(.red) }
                    Section {
                        Button("Show them") { dismiss(); router.open("#/photos?edited=1") }
                        Button(working ? "Updating…" : "Apply to digiKam database") {
                            working = true
                            Task {
                                do {
                                    let r = try await AdminAPI.post("api/edits/db")
                                    problem = nil
                                    self.st?["pending"] = 0
                                    let skipped = r.list("skipped")
                                    problem = "Updated \(AdminFormat.plural(r.int("applied") ?? 0, "photo")) in digiKam's database." + (skipped.isEmpty ? "" : " \(skipped.count) skipped: \(skipped[0].str("reason") ?? "").")
                                    await done()
                                } catch { problem = error.localizedDescription }
                                working = false
                            }
                        }
                        .disabled(working || st.bool("digikamRunning") || (st.int("pending") ?? 0) == 0)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Apply edits to digiKam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { BarText("Done") } } }
            .task {
                do { st = try await AdminAPI.get("api/edits/db") } catch { problem = error.localizedDescription; st = [:] }
            }
        }
    }
}

// MARK: - Metadata consistency

/// Rating, title, caption, tags, date and location, read from digiKam's database, the XMP sidecar and the file, and
/// compared: fix a photo with its buttons, or select several and take the values from one place.
struct AdminConsistencyScreen: View {
    @AppStorage(ManageThumbSize.key) private var thumbSize = "list"
    @StateObject private var notice = AdminNotice()
    @State private var field = ""
    @State private var d: [String: Any] = [:]
    @State private var items: [[String: Any]] = []
    @State private var selected: Set<Int> = []
    @State private var confirm: AdminConfirm?
    @State private var poll: Task<Void, Never>?
    @State private var wasRunning = false
    @State private var editing = true
    @State private var gone = false
    /// The filters of a search to check on its own (this screen has no current search of its own, as the web app's
    /// grid has when it offers "Check the current search only").
    @State private var searchQuery = ""

    static let sources = [("db", "Database"), ("sidecar", "Sidecar"), ("file", "Image file")]
    static let fields: [String: String] = ["rating": "Rating", "title": "Title", "caption": "Caption", "tags": "Tags", "taken": "Date", "gps": "Location"]
    static let fieldOrder = ["rating", "title", "caption", "tags", "taken", "gps"]

    private var summary: [String: Any] { d.dict("summary") }
    private var progress: [String: Any] { d.dict("progress") }

    var body: some View {
        List {
            Section {
                Text("Each photo's rating, title, caption and tags are read from digiKam's database, its XMP sidecar and the image file, and compared. Files that cannot hold metadata (most videos, RAW) show n/a, which is not a disagreement.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { Task { await scan(all: false) } } label: { Label("Check new and changed photos", systemImage: "sparkles") }
                Button("Check every photo again") {
                    confirm = AdminConfirm(title: "Re-check every photo in the library?", message: "This reads every sidecar and image file and takes a while.", button: "Check") { await scan(all: true) }
                }
            }
            Section {
                TextField("year=2020&tag=12", text: $searchQuery).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Check this search only") { Task { await scan(all: true, query: searchQuery) } }
                    .disabled(PhotoQuery(query: searchQuery.trimmingCharacters(in: .whitespaces)).filters.isEmpty)
            } header: { Text("Check a search only") } footer: {
                Text("The web app checks the photos of the search shown above its grid; this screen has no search of its own, so type the filters of one here, as they follow #/photos? in a link (Copy link under Albums gives them).")
            }
            if progress.bool("running") {
                Section { AdminProgress(done: progress.int("done") ?? 0, total: progress.int("total") ?? 0, label: "Checking…") }
            }
            if let n = progress.int("failed"), n > 0, !progress.bool("running") {
                Text("\(AdminFormat.n(n)) photos could not be compared: \(progress.str("error") ?? "")").foregroundStyle(.orange)
            }
            if (summary.int("scanned") ?? 0) > 0 {
                Section {
                    Picker("Show", selection: $field) {
                        Text("Disagree (\(AdminFormat.n(summary.int("mismatched"))))").tag("")
                        Text("No sidecar (\(AdminFormat.n(summary.int("no_sidecar"))))").tag("nosidecar")
                        ForEach(Self.fieldOrder, id: \.self) { f in
                            if let n = summary.dict("by_field").int(f), n > 0 { Text("\(Self.fields[f] ?? f) differs (\(AdminFormat.n(n)))").tag(f) }
                        }
                    }
                    Text("\(AdminFormat.n(summary.int("scanned"))) photos checked\(summary.dbl("scanned_at").map { ", last on \(AdminFormat.when($0))" } ?? "").")
                        .font(.footnote).foregroundStyle(.secondary)
                    if editing && (d.int("total") ?? 0) > 0 {
                        Button("Select all \(AdminFormat.n(d.int("total")))") { Task { await selectAll() } }
                    }
                } header: { Text(field == "nosidecar" ? "Photos without a sidecar" : field.isEmpty ? "Photos that disagree" : "Photos whose \((Self.fields[field] ?? field).lowercased()) differs") }
                Section {
                    if items.isEmpty {
                        Text(field == "nosidecar" ? "Every photo has a sidecar." : "Everything that was checked agrees.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(items.enumerated()), id: \.offset) { _, r in row(r) }
                    if items.count < (d.int("total") ?? 0) {
                        Button("Show more") { Task { await load(append: true) } }
                    }
                }
            } else if !progress.bool("running") {
                Section { Text("Nothing checked yet.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Metadata consistency")
        .toolbar { ManageThumbSizeMenu() }
        .safeAreaInset(edge: .bottom) { if !selected.isEmpty { bar } }
        .task { editing = ((try? await AdminAPI.get("api/status"))?.bool("editing")) ?? true; await load() }
        .onChange(of: field) { _, _ in selected = []; Task { await load() } }
        .onAppear { gone = false }
        .onDisappear { gone = true; poll?.cancel() }
        .refreshable { await load() }
        .adminConfirm($confirm)
        .adminNotice(notice)
    }

    @ViewBuilder private func row(_ r: [String: Any]) -> some View {
        let id = r.int("id") ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if editing {
                    Button { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } } label: {
                        Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle").font(.title3)
                    }
                    .buttonStyle(.borderless)
                }
                RemoteImage(path: "thumb/\(id)").frame(width: max(48, ManageThumbSize.side(thumbSize) * 4 / 3), height: max(48, ManageThumbSize.side(thumbSize))).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.str("name") ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(pathNote(r)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if field == "nosidecar" {
                if editing { Button("Create sidecar") { makeSidecars([id]) }.buttonStyle(.bordered).font(.caption) }
            } else {
                let mismatch = r.strings("mismatch")
                let fields = r.dict("fields")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("").font(.caption2)
                        ForEach(Self.sources, id: \.0) { Text($0.1).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                    }
                    ForEach(mismatch, id: \.self) { f in
                        GridRow {
                            Text(Self.fields[f] ?? f).font(.caption2.weight(.semibold))
                            ForEach(Self.sources, id: \.0) { s in
                                Text(value(f, fields.dict(f)[s.0], na: s.0 == "file" && !r.bool("file_xmp") && !r.bool("file_editable")))
                                    .font(.caption2).lineLimit(3)
                            }
                        }
                    }
                }
                if editing {
                    HStack {
                        Text("Take the values from:").font(.caption).foregroundStyle(.secondary)
                        ForEach(Self.sources.filter { s in mismatch.contains { f in !(fields.dict(f)[s.0] is NSNull) && fields.dict(f)[s.0] != nil } }, id: \.0) { s in
                            Button(s.1) { fixOne(r, s.0) }.buttonStyle(.bordered).font(.caption)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func pathNote(_ r: [String: Any]) -> String {
        var t = (r.str("path") ?? "").replacingOccurrences(of: #"^.*/photos/"#, with: "", options: .regularExpression)
        if !r.bool("has_sidecar") { t += " · no sidecar" }
        if !r.bool("file_xmp") { t += r.bool("file_editable") ? " · no metadata in the file" : " · file type cannot hold metadata" }
        return t
    }

    private func value(_ f: String, _ v: Any?, na: Bool) -> String {
        if na { return "n/a" }
        guard let v, !(v is NSNull) else { return "absent" }
        if f == "tags" { let t = (v as? [Any] ?? []).compactMap { ($0 as? String)?.split(separator: "/").last.map(String.init) }; return t.isEmpty ? "none" : t.joined(separator: ", ") }
        if f == "rating" { let n = (v as? NSNumber)?.intValue ?? 0; return n > 0 ? String(repeating: "★", count: n) : "none" }
        let s = (v as? String) ?? "\(v)"
        return s.isEmpty ? "empty" : s
    }

    private var bar: some View {
        VStack(spacing: 8) {
            HStack {
                Button { selected = [] } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear the selection")
                Text("\(AdminFormat.n(selected.count)) selected").font(.subheadline.weight(.medium))
                Spacer()
            }
            if field == "nosidecar" {
                Button("Create sidecars from digiKam's database") { makeSidecars(Array(selected)) }.buttonStyle(.borderedProminent)
            } else {
                HStack {
                    Text("Take the values from:").font(.caption).foregroundStyle(.secondary)
                    ForEach(Self.sources, id: \.0) { s in
                        Button(s.1) { bulk(s.0) }.buttonStyle(.bordered).font(.caption)
                    }
                }
            }
        }
        .padding(12)
        .background(.bar)
    }

    private func targetsText(_ t: [String]) -> String { t.map { k in (Self.sources.first { $0.0 == k }?.1 ?? k).lowercased() }.joined(separator: " and ") }

    private func fixOne(_ r: [String: Any], _ src: String) {
        let targets = Self.sources.map(\.0).filter { $0 != src && ($0 != "file" || r.bool("file_editable")) }
        let mismatch = r.strings("mismatch")
        confirm = AdminConfirm(title: "Copy \(mismatch.map { (Self.fields[$0] ?? $0).lowercased() }.joined(separator: ", ")) from the \(targetsText([src])) to the \(targetsText(targets))?",
                               message: (r.str("name") ?? "") + (targets.contains("db") ? ". This writes into digiKam's database." : "."), button: "Copy") {
            await notice.run(nil) {
                let res = try await AdminAPI.post("api/consistency/sync", ["ids": [r.int("id") ?? 0], "source": src, "targets": targets, "fields": mismatch])
                notice.say((res.int("synced") ?? 0) > 0 ? "Fixed \(r.str("name") ?? "")." : "Not fixed: \(res.list("skipped").first?.str("reason") ?? "nothing to copy")")
                await load()
            }
        }
    }

    private func bulk(_ src: String) {
        let targets = Self.sources.map(\.0).filter { $0 != src }
        let n = selected.count
        var msg = "For \(AdminFormat.plural(n, "photo")). Sidecars are backed up before they change."
        if targets.contains("db") { msg += " This writes into digiKam's database." }
        if targets.contains("file") { msg += " Image files are rewritten in place (metadata only); the original of each is kept in the file-backups folder. Files that cannot hold metadata are skipped." }
        confirm = AdminConfirm(title: "Copy every field from the \(targetsText([src])) to the \(targetsText(targets))?", message: msg, button: "Sync") {
            await notice.run(nil) {
                let r = try await AdminAPI.post("api/consistency/sync", ["ids": Array(selected), "source": src, "targets": targets, "fields": Self.fieldOrder])
                let skipped = r.list("skipped")
                notice.say("Synced \(AdminFormat.plural(r.int("synced") ?? 0, "photo"))\(skipped.isEmpty ? "" : "; \(skipped.count) skipped (\(skipped[0].str("reason") ?? ""))").")
                selected = []
                await load()
            }
        }
    }

    private func makeSidecars(_ ids: [Int]) {
        let go = {
            var done = 0, skipped: [[String: Any]] = []
            for start in stride(from: 0, to: ids.count, by: 200) {
                do {
                    let r = try await AdminAPI.post("api/consistency/sync", ["ids": Array(ids[start..<min(start + 200, ids.count)]), "source": "db", "targets": ["sidecar"], "fields": Self.fieldOrder])
                    done += r.int("synced") ?? 0
                    skipped += r.list("skipped")
                } catch { notice.fail(error); break }
            }
            notice.say("Created \(AdminFormat.plural(done, "sidecar"))\(skipped.isEmpty ? "" : "; \(skipped.count) skipped (\(skipped[0].str("reason") ?? ""))").")
            selected = []
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await load()
        }
        if ids.count > 1 {
            confirm = AdminConfirm(title: "Create an XMP sidecar for \(AdminFormat.n(ids.count)) photos?", message: "With the rating, title, caption and tags from digiKam's database. Nothing else changes.", button: "Create") { await go() }
        } else {
            Task { await go() }
        }
    }

    /// Starts a check: of new and changed photos, of every photo, or (with `query`, the filters of a search) of the
    /// photos a search finds, all of them again.
    private func scan(all: Bool, query: String? = nil) async {
        await notice.run(nil) {
            var items = query.map { PhotoQuery(query: $0.trimmingCharacters(in: .whitespaces)).filters } ?? []
            items.append(URLQueryItem(name: "rescan_all", value: all ? "1" : "0"))
            let r = try await AdminAPI.postForm("api/consistency/scan", items)
            notice.say("Checking \(AdminFormat.n(r.int("queued"))) photos in the background.")
            wasRunning = true
            await load()
        }
    }

    private func selectAll() async {
        guard let all = try? await AdminAPI.get("api/consistency", [URLQueryItem(name: "field", value: field), URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "5000")]) else { return }
        selected.formUnion(all.list("items").compactMap { $0.int("id") })
    }

    private func load(append: Bool = false) async {
        let offset = append ? items.count : 0
        guard let r = try? await AdminAPI.get("api/consistency", [URLQueryItem(name: "field", value: field), URLQueryItem(name: "offset", value: "\(offset)"), URLQueryItem(name: "limit", value: "60")]) else { return }
        d = r
        items = append ? items + r.list("items") : r.list("items")
        let running = r.dict("progress").bool("running")
        if wasRunning && !running {
            let s = r.dict("summary"), failed = r.dict("progress").int("failed") ?? 0
            notice.say(failed > 0 ? "Check finished with errors: \(AdminFormat.n(failed)) photos could not be compared." : "Check finished: \(AdminFormat.n(s.int("scanned"))) photos compared, \(AdminFormat.n(s.int("mismatched"))) disagree.")
        }
        wasRunning = running
        poll?.cancel()
        if gone || Task.isCancelled { return }
        if running {
            poll = Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if !Task.isCancelled { await load() } }
        }
    }
}
