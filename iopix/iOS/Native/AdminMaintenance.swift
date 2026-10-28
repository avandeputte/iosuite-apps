import SwiftUI

/// Maintenance, for admins, grouped as the web app does: the library, AI analysis and models, storage and backups,
/// and the server itself (edit log, server log, version and updates, restart).
struct AdminMaintenanceScreen: View {
    @EnvironmentObject private var router: Router
    @StateObject private var notice = AdminNotice()
    @State private var m: [String: Any] = [:]
    @State private var status: [String: Any] = [:]
    @State private var consistency: String?
    @State private var quality: String?
    @State private var damaged: String?  // the file check in one line; nil when the server has none
    @State private var applying = false
    @State private var confirm: AdminConfirm?
    @State private var problem: String?

    private var appName: String { status.str("appName") ?? "iopix" }

    var body: some View {
        List {
            if let problem, m.isEmpty {
                Section { Text(problem).foregroundStyle(.secondary) }
            }
            if !m.isEmpty {
                Section {
                    Text(intro).font(.footnote).foregroundStyle(.secondary)
                }
                library
                Section("AI analysis and models") {
                    NavigationLink { AdminModelsScreen() } label: {
                        Label("Jobs and models", systemImage: "sparkles")
                    }
                }
                Section("Storage and backups") {
                    NavigationLink { AdminStorageScreen(m: m) { await load() } } label: {
                        AdminRow(title: "Storage and backups") { Text("\(AdminFormat.bytes(m.dict("storage").dbl("free"))) free").foregroundStyle(.secondary) }
                    }
                }
                server
            } else if problem == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Maintenance")
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $applying) { AdminApplyEditsSheet(appName: appName) { await load() } }
        .adminConfirm($confirm)
        .adminNotice(notice)
    }

    private var intro: String {
        let p = m.dict("paths")
        if let lib = p.str("library") {
            return "Library: \(lib) (\(AdminFormat.n(m.int("photos"))) photos and videos). digiKam database: \(p.str("digikamDb") ?? "?"). Everything \(appName) writes lives in \(p.str("data") ?? "?")."
        }
        return "\(AdminFormat.n(m.int("photos"))) photos in the library."
    }

    // MARK: library

    @ViewBuilder private var library: some View {
        let sc = m.dict("scanner")
        Section("Library") {
            Button { router.open("#/import") } label: {
                AdminRow(title: "Import", detail: "Photos and videos from a phone, a card or a computer, into folders by date, duplicates left out.")
            }
            .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("File scanner", isOn: Binding(get: { sc.bool("enabled") }, set: { on in
                    Task { await notice.run(on ? "File scanner on: a first pass starts now." : "File scanner off.") { try await AdminAPI.post("api/settings", ["file_scanner": on]); await load() } }
                }))
                .font(.body.weight(.medium))
                Picker("How often", selection: Binding(get: { sc.int("interval") ?? 15 }, set: { v in
                    Task { await notice.run(nil) { try await AdminAPI.post("api/settings", ["scan_interval": v]); await load() } }
                })) {
                    Text("Every 5 minutes").tag(5); Text("Every 15 minutes").tag(15); Text("Every hour").tag(60)
                    Text("Every 6 hours").tag(360); Text("Once a day").tag(1440)
                }
                Text("Looks in the album folders for photos and videos added, changed or removed outside \(appName) (Finder, a sync tool, a phone backup), as digiKam's scanner does. Leave it off if everything arrives through Upload or Import. " + scannerText(sc))
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Scan now") {
                    Task { await notice.run("Scanning the album folders…") { try await AdminAPI.post("api/scan"); try? await Task.sleep(nanoseconds: 4_000_000_000); await load() } }
                }
            }
            let lossless = status.dict("lossless")
            AdminRow(title: "Lossless JPEG edits",
                     detail: lossless.bool("jpegtran") ? "jpegtran is installed: JPEGs are rotated, flipped and cropped without re-encoding."
                        : "jpegtran (libjpeg-turbo) is not installed on the server, so JPEGs are turned by their orientation flag only and cannot be cropped. Install it there: apt-get install -y libjpeg-turbo-progs, dnf install libjpeg-turbo-utils, or brew install jpeg-turbo.") {
                Text(lossless.bool("jpegtran") ? "Installed" : lossless.isEmpty ? "Editing off" : "Missing").foregroundStyle(lossless.bool("jpegtran") ? .green : .orange)
            }
            Button { router.open("#/trash") } label: {
                AdminRow(title: "Trash", detail: "Photos moved to the trash here or in digiKam, with their sidecars, until restored or deleted for good.")
            }
            .foregroundStyle(.primary)
            AdminRow(title: "Library copy", detail: libraryCopyText)
            VStack(alignment: .leading, spacing: 6) {
                AdminRow(title: "Rescan the library", detail: "The index is rebuilt from digiKam's database whenever digiKam saves (last saved \(AdminFormat.when(m.dbl("digikamSaved"))); index built \(AdminFormat.when(m.dbl("indexBuilt")))). Force it here if something looks stale.")
                Button("Rescan now") { action("reindex", "Rescanning the library…") }
            }
            NavigationLink { AdminConsistencyScreen() } label: {
                AdminRow(title: "Metadata consistency", detail: (consistency ?? "Loading…") + " Rating, title, caption and tags are compared in the three places they live.")
            }
            Button { router.open("#/quality") } label: {
                AdminRow(title: "Metadata quality", detail: (quality ?? "Checking…") + " Duplicate faces, the same person twice, and boxes outside the photo.")
            }
            .foregroundStyle(.primary)
            if damaged != nil {  // iopix 1.86 and later
                NavigationLink { AdminDamagedScreen(canEdit: status.bool("editing")) } label: {
                    AdminRow(title: "Damaged files", detail: (damaged ?? "") + "Every file read and checked: JPEGs that stop early or lack their end marker, damaged PNGs, pictures that cannot be decoded; a safe repair where there is one.")
                }
            }
            if status.bool("editing") {
                let pending = m.int("pendingEdits") ?? 0
                VStack(alignment: .leading, spacing: 6) {
                    AdminRow(title: "Edits waiting for digiKam",
                             detail: pending > 0 ? "\(AdminFormat.plural(pending, "photo has", "photos have")) edits saved in sidecars that digiKam's database does not have yet. digiKam is \(m.bool("digikamRunning") ? "running, so they cannot be applied right now" : "closed, so they can be applied now")."
                                : "None. digiKam's database and the sidecars agree.")
                    if pending > 0 { Button("Apply to digiKam database…") { applying = true } }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                AdminRow(title: "Tag cover photos", detail: "The photo shown for each tag is chosen by the content model. Pick them again after big tagging changes.")
                Button("Pick again") { action("covers", "Choosing tag covers in the background.") }
            }
        }
    }

    private var libraryCopyText: String {
        let d = m.dict("digikam"), mir = d.dict("mirror")
        guard !mir.isEmpty else { return "Not taken yet; it is taken at the next read of digiKam's database." }
        return "\(appName)'s own copy of the library's metadata: \(AdminFormat.n(mir.int("photos"))) photos as of \(AdminFormat.when(mir.dbl("taken"))). The index is built from it whenever digiKam's database is unreachable or Sync with digiKam is off\(d.str("source") == "mirror" ? " (as it is now)" : "")."
    }

    private func scannerText(_ sc: [String: Any]) -> String {
        if sc.bool("running") { return "Scanning now…" }
        let last = sc.dict("last")
        guard !last.isEmpty else { return "No pass yet." }
        let parts = [last.int("added").flatMap { $0 > 0 ? AdminFormat.plural($0, "new file") : nil },
                     last.int("modified").flatMap { $0 > 0 ? AdminFormat.plural($0, "changed file") : nil },
                     last.int("removed").flatMap { $0 > 0 ? AdminFormat.plural($0, "file") + " gone" : nil },
                     last.int("folders").flatMap { $0 > 0 ? AdminFormat.plural($0, "new folder") : nil }].compactMap { $0 }
        return "Last pass \(AdminFormat.when(last.dbl("finished"))): \(parts.isEmpty ? "nothing new" : parts.joined(separator: ", ")).\(last.str("error").map { " Error: \($0)" } ?? "")"
    }

    // MARK: the server

    @ViewBuilder private var server: some View {
        Section(appName) {
            Button { router.open("#/history") } label: {
                AdminRow(title: "Edit log", detail: "Every change made in \(appName), for every photo: who, when, before and after, with undo.")
            }
            .foregroundStyle(.primary)
            NavigationLink { AdminLogScreen() } label: {
                AdminRow(title: "Server log", detail: "What the server has been doing: edits, database writes, updates, background jobs and errors.")
            }
            AdminUpdateRow(appName: appName)
            VStack(alignment: .leading, spacing: 6) {
                AdminRow(title: "Restart \(appName)", detail: "Stops the server; launchd, Docker or systemd starts it again within seconds. Handy when a background job looks stuck.")
                Button("Restart", role: .destructive) {
                    confirm = AdminConfirm(title: "Restart \(appName) now?", message: "Anyone using it is disconnected for a few seconds.", button: "Restart", destructive: true) {
                        await notice.run("Restarting…") { try await AdminAPI.post("api/restart") }
                    }
                }
            }
        }
    }

    private func action(_ a: String, _ done: String, confirmText: String? = nil) {
        let run = { await notice.run(done) { try await AdminAPI.post("api/maintenance", ["action": a]); try? await Task.sleep(nanoseconds: 1_500_000_000); await load() } }
        if let confirmText {
            confirm = AdminConfirm(title: confirmText, button: "Continue") { await run() }
        } else {
            Task { await run() }
        }
    }

    private func load() async {
        do {
            async let a = AdminAPI.get("api/maintenance")
            async let b = AdminAPI.get("api/status")
            let got = try await a
            status = (try? await b) ?? status
            if got.dict("paths").isEmpty {  // the server leaves the paths and storage out for everyone but admins
                m = [:]
                problem = "Maintenance is for admins."
                return
            }
            m = got
            problem = nil
        } catch {
            problem = "Couldn't load Maintenance: \(error.localizedDescription)"
            return
        }
        if let c = try? await AdminAPI.get("api/consistency", [URLQueryItem(name: "limit", value: "1")]) {
            let s = c.dict("summary"), p = c.dict("progress")
            consistency = p.bool("running") ? "Checking… \(AdminFormat.n(p.int("done"))) / \(AdminFormat.n(p.int("total"))) photos."
                : (s.int("scanned") ?? 0) == 0 ? "Not checked yet."
                : "\((s.int("mismatched") ?? 0) > 0 ? AdminFormat.plural(s.int("mismatched") ?? 0, "photo disagrees", "photos disagree") : "Everything agrees") across digiKam's database, the sidecars and the files\(s.dbl("scanned_at").map { " (last checked \(AdminFormat.when($0)))" } ?? "")."
        }
        if let q = try? await AdminAPI.get("api/quality") {
            var t = (q.dict("near").int("extra") ?? 0) > 0 ? "\(AdminFormat.plural(q.dict("near").int("extra")!, "face is", "faces are")) stored twice. " : "No face is stored twice. "
            if let n = q.dict("separate").int("count"), n > 0 { t += "\(AdminFormat.plural(n, "photo has", "photos have")) the same person in two places. " }
            if let n = q.dict("unnamed").int("count"), n > 0 { t += "\(AdminFormat.plural(n, "photo has", "photos have")) faces but no names. " }
            if let n = q.dict("untagged").int("count"), n > 0 { t += "\(AdminFormat.plural(n, "photo shows", "photos show")) people but nobody is tagged. " }
            if let n = q.dict("invalid").int("count"), n > 0 { t += "\(AdminFormat.plural(n, "box is", "boxes are")) outside the photo or empty." }
            quality = t
        }
        if let f = try? await AdminAPI.get("api/filecheck") {
            let p = f.dict("progress"), found = f.list("found")
            damaged = p.bool("running") ? "Checking… \(AdminFormat.n(p.int("done"))) / \(AdminFormat.n(p.int("total"))) files. "
                : (f.int("checked") ?? 0) == 0 ? "Not checked yet. "
                : !found.isEmpty ? "\(AdminFormat.plural(found.count, "damaged file")) found (\(found.filter { $0.bool("fixable") }.count) repairable). "
                : "Nothing damaged found. "
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

// MARK: - AI analysis and models

/// Every analysis job with its model, progress and actions; models without a job (place names) after them.
struct AdminModelsScreen: View {
    @StateObject private var notice = AdminNotice()
    @State private var a: [String: Any] = [:]
    @State private var md: [String: Any] = [:]
    @State private var checking = false
    @State private var confirm: AdminConfirm?
    @State private var poll: Task<Void, Never>?
    @State private var gone = false
    /// The "Compare the N models" folds opened; they stay open while the list is redrawn.
    @State private var openCompare: Set<String> = []

    /// A job's models: fixed ones (text reading: RapidOCR; photo quality: the aesthetic and eye models; ages for date
    /// suggestions: MiVOLO) or the one chosen for its feature, as the web app's Maintenance lists them (iopix 1.83.1).
    private static let jobModel = ["vision": ["ocr"], "looks": ["aesthetic", "eyes"], "ages": ["mivolo"]]
    private static let jobChoice = ["embeddings": "search_model", "objects": "object_model", "faces": "face_vectors", "facedetect": "face_detector", "captions": "caption_model"]

    private var models: [String: [String: Any]] { Dictionary(md.list("models").compactMap { m in m.str("key").map { ($0, m) } }, uniquingKeysWith: { x, _ in x }) }
    private var choices: [String: Any] { md.dict("choices") }
    private var progress: [String: Any] { md.dict("progress") }

    var body: some View {
        List {
            Section {
                Text("Everything runs on the server and is stored in its data folder; nothing is written to digiKam. New and changed photos are picked up automatically. Where a feature can run on more than one model, the default is the small, fast one; the others are more accurate and slower, each downloaded once. Models never update on their own.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { Task { await notice.run("Checking for new and changed photos…") { try await AdminAPI.post("api/analysis/run", ["job": "all"]); await load() } } } label: {
                    Label("Check new and changed photos", systemImage: "sparkles")
                }
                Button {
                    checking = true
                    Task { await notice.run(nil) { try await AdminAPI.post("api/models/check") }; checking = false; await load() }
                } label: { Label(checking ? "Checking…" : "Check models for updates", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(checking)
                Text(backgroundText).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(a.list("jobs").enumerated()), id: \.offset) { _, j in
                let key = j.str("key") ?? ""
                let group = Self.jobChoice[key].flatMap { choices[$0] != nil ? $0 : nil }
                let keys = group.flatMap { (choices[$0] as? [String: Any])?.str("chosen") }.map { [$0] } ?? Self.jobModel[key] ?? []
                jobSection(j, models: keys.compactMap { models[$0] }, group: group)
            }
            // a model shown on its job's row is not listed again; the rest (place names) get a section each
            let inRows = Set(choices.values.compactMap { ($0 as? [String: Any])?.strings("options") }.flatMap { $0 } + Self.jobModel.values.flatMap { $0 })
            let extra = md.list("models").filter { !inRows.contains($0.str("key") ?? "") }
            ForEach(extra.indices, id: \.self) { i in modelOnlySection(extra[i]) }
        }
        .navigationTitle("AI analysis and models")
        .task { await load() }
        .refreshable { await load() }
        .onAppear { gone = false }
        .onDisappear { gone = true; poll?.cancel() }
        .adminConfirm($confirm)
        .adminNotice(notice)
    }

    private var backgroundText: String {
        let q = a.dict("queue")
        let running = q.str("running").map { r in a.list("jobs").first { $0.str("key") == r || (r == "pixels" && $0.str("key") == "quality") }?.str("label") ?? r }
        return "Background work: \(running.map { "running \($0)" } ?? "idle"). Jobs run one at a time, in the order below, each with up to \(q.int("threads") ?? 1) of \(q.int("cores").map(String.init) ?? "?") cores (change that in Settings › AI and search).\((q["queued"] as? [Any])?.isEmpty == false ? " Waiting: \((q["queued"] as? [Any])?.count ?? 0)." : "")"
    }

    private func jobSection(_ j: [String: Any], models jobModels: [[String: Any]], group: String?) -> some View {
        let done = j.int("done") ?? 0, total = j.int("total") ?? 0
        let state = !j.bool("enabled") ? (jobModels.contains { !$0.bool("installed") } ? "needs its model" : "off")
            : j.bool("running") ? "running…" : j.bool("queued") ? "queued" : done >= total ? "up to date" : j.str("key") == "facedetect" ? "on request" : "waiting"
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(j.str("label") ?? "").font(.body.weight(.medium))
                    Spacer()
                    Text(state).font(.caption).foregroundStyle(j.bool("running") ? .blue : done >= total && j.bool("enabled") ? .green : .secondary)
                }
                if let d = j.str("detail") { Text(d).font(.footnote).foregroundStyle(.secondary) }
                AdminProgress(done: done, total: total)
                if j.bool("running"), let since = j.dbl("since") { Text(runningText(j, since)).font(.caption).foregroundStyle(stuck(j, since) ? .orange : .secondary) }
            }
            if jobModels.isEmpty {
                Text("Built in").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(Array(jobModels.enumerated()), id: \.offset) { _, m in modelRows(m, group: group) }
            }
            if j.str("key") == "facedetect" && j.bool("enabled") && !j.bool("running") && done < total {
                Button("Look for faces now") {
                    confirm = AdminConfirm(title: "Look for faces in the \(AdminFormat.n(total - done)) photos not checked yet?", message: "New faces are added to digiKam's database as unnamed faces; faces already marked stay as they are.", button: "Look for faces") {
                        await notice.run(nil) {
                            let r = try await AdminAPI.post("api/analysis/run", ["job": "facedetect"])
                            notice.say("Looking for faces in \(AdminFormat.n(r.int("queued"))) photos.")
                            await load()
                        }
                    }
                }
            }
            if j.bool("rerun") && j.bool("enabled") {
                Button("Run again from scratch") {
                    confirm = AdminConfirm(title: "Run “\(j.str("label") ?? "")” again for all \(AdminFormat.n(total)) photos?", message: "The current results for it are discarded first. This can take from several minutes to a few hours.", button: "Run again", destructive: true) {
                        await notice.run("Re-running “\(j.str("label") ?? "")”.") { try await AdminAPI.post("api/analysis/run", ["job": j.str("key") ?? "", "reset": true]); await load() }
                    }
                }
            }
        }
    }

    @ViewBuilder private func modelRows(_ m: [String: Any], group: String?) -> some View {
        if let group, let c = choices[group] as? [String: Any] {
            Picker(c.str("label") ?? "Model", selection: Binding(get: { c.str("chosen") ?? "" }, set: { key in choose(group, key, c) })) {
                ForEach(c.strings("options"), id: \.self) { k in
                    Text((models[k]?.str("label") ?? k) + (models[k]?.bool("installed") == false ? " (not installed)" : "")).tag(k)
                }
            }
        } else {
            AdminRow(title: m.str("label") ?? "") { Text(m.str("size") ?? "").foregroundStyle(.secondary) }
        }
        HStack {
            Text("\(m.str("size") ?? "") · \(modelState(m))").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let page = m.str("page"), let url = URL(string: page) { Link("About", destination: url).font(.caption) }
        }
        if let what = m.str("what"), group != nil { Text(what).font(.caption).foregroundStyle(.secondary) }
        if let label = modelButton(m) {
            Button(label) { download(m) }.disabled(progress.str("running") != nil)
        }
        if let group, let c = choices[group] as? [String: Any], c.strings("options").count > 1 { compare(group, c) }
    }

    /// What each choice of a feature's model is: size, installed or in use, and the registry's own words on its
    /// speed and accuracy, folded under "Compare the N models" as the web app has it.
    private func compare(_ group: String, _ c: [String: Any]) -> some View {
        let options = c.strings("options")
        return DisclosureGroup(isExpanded: Binding(get: { openCompare.contains(group) }, set: { if $0 { openCompare.insert(group) } else { openCompare.remove(group) } })) {
            ForEach(options, id: \.self) { k in
                if let o = models[k] {
                    let chosen = k == c.str("chosen")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(o.str("label") ?? k).font(.subheadline.weight(chosen ? .semibold : .regular))
                            Text("· \(o.str("size") ?? "")\(chosen ? " · in use" : o.bool("installed") ? " · installed" : " · not installed")").font(.caption).foregroundStyle(.secondary)
                            if let page = o.str("page"), let url = URL(string: page) { Link("About", destination: url).font(.caption) }
                        }
                        if let what = o.str("what") { Text(what).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 2)
                }
            }
        } label: { Text("Compare the \(options.count) models").font(.subheadline) }
    }

    private func modelOnlySection(_ m: [String: Any]) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.str("key") == "geonames" ? "Places from GPS positions" : (m.str("label") ?? "")).font(.body.weight(.medium))
                Text(m.str("key") == "geonames" ? "Town, region and country for each GPS position, offline; looked up when the search index is built." : (m.str("what") ?? ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            modelRows(m, group: nil)
        }
    }

    private func modelState(_ m: [String: Any]) -> String {
        let c = m.dict("check")
        if progress.str("running") == m.str("key") { return "downloading…" }
        if !m.bool("installed") { return "not installed" }
        switch c.str("status") {
        case nil: return "installed \(m.dbl("at").map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) } ?? "")"
        case "current": return "up to date"
        case "update": return "update available (\(c.str("remote") ?? ""))"
        case "newer": return "newer data available"
        case "error": return "could not check"
        default: return "installed \(m.str("revision") ?? "")"
        }
    }

    /// Download for a model not installed; Update when a newer one is out; nothing when installed and current.
    private func modelButton(_ m: [String: Any]) -> String? {
        let s = m.dict("check").str("status")
        let upd = s == "update" || s == "newer" || s == "missing"
        if m.bool("installed") && !upd { return nil }
        return m.bool("installed") ? "Update" : "Download"
    }

    private func download(_ m: [String: Any]) {
        let label = m.str("label") ?? "the model"
        confirm = AdminConfirm(title: "Download \(label) (\(m.str("size") ?? ""))\(m.bool("installed") ? " again" : "")?",
                               message: "The server keeps working meanwhile." + (m.str("kind") == "pip" ? " A package update takes effect after a restart." : ""), button: "Download") {
            await notice.run("Downloading \(label)…") { try await AdminAPI.post("api/models/download", ["key": m.str("key") ?? ""]); await load() }
        }
    }

    private func choose(_ group: String, _ key: String, _ c: [String: Any]) {
        guard key != c.str("chosen"), let m = models[key] else { return }
        if !m.bool("installed") { download(m); return }
        let note = group == "search_model" ? " The library is indexed again with it in the background; search stays on the current model until that finishes."
            : group == "face_vectors" ? " Every face is embedded again with it."
            : group == "face_detector" ? " Used by the next face detection run."
            : " New photos use it from now on; “Run again from scratch” redoes the whole library with it."
        Task { await notice.run("\(c.str("label") ?? ""): now \(m.str("label") ?? key).\(note)") { try await AdminAPI.post("api/settings", [group: key]); await load() } }
    }

    private func runningText(_ j: [String: Any], _ since: Double) -> String {
        let now = Date().timeIntervalSince1970
        let idle = j.dbl("last").map { now - $0 } ?? (now - since)
        let cur = j.strings("current").map { ($0 as NSString).lastPathComponent }
        return "Running for \(Int((now - since) / 60)) min · last progress \(idle < 90 ? "\(Int(idle)) s" : "\(Int(idle / 60)) min") ago" + (cur.isEmpty ? "" : " · \(cur.joined(separator: ", "))")
            + (stuck(j, since) ? " · probably stuck on that file: see the server log, or restart from Maintenance" : "")
    }

    private func stuck(_ j: [String: Any], _ since: Double) -> Bool {
        let now = Date().timeIntervalSince1970
        return (j.dbl("last").map { now - $0 } ?? (now - since)) > 300
    }

    private func load() async {
        async let x = AdminAPI.get("api/analysis")
        async let y = AdminAPI.get("api/models")
        if let v = try? await x { a = v }
        if let v = try? await y { md = v }
        if let e = progress.str("error"), !e.isEmpty, progress.str("running") == nil, let f = progress.str("finished") {
            notice.say("Download of \(f) failed: \(e)", error: true)
        }
        poll?.cancel()
        if gone || Task.isCancelled { return }  // a load that finished after the screen went: no more polling
        if a.list("jobs").contains(where: { $0.bool("running") }) || progress.str("running") != nil {
            poll = Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled { await load() }
            }
        }
    }
}

// MARK: - Storage and backups

struct AdminStorageScreen: View {
    let m: [String: Any]
    let changed: () async -> Void
    @StateObject private var notice = AdminNotice()
    @State private var confirm: AdminConfirm?
    @State private var sharing: AdminSharedFile?
    @State private var downloading: String?
    @State private var fresh: [String: Any]?  // the sizes after an action here (the parent's copy is what it was when this opened)

    private var st: [String: Any] { (fresh ?? m).dict("storage") }

    var body: some View {
        List {
            Section {
                item("Thumbnails", st.dbl("thumbnails"), "Grid previews, rebuilt in the background (several minutes).") {
                    Button("Rebuild") {
                        confirm = AdminConfirm(title: "Delete all grid thumbnails (\(AdminFormat.bytes(st.dbl("thumbnails")))) and rebuild them?", button: "Rebuild") { await act("thumbs", "Rebuilding thumbnails in the background.") }
                    }
                }
                item("Previews", st.dbl("previews"), "Large images, remade on demand.") { Button("Clear") { Task { await act("previews", "Previews cleared; they are remade as you open photos.") } } }
                item("Face crops", st.dbl("faces"), "Remade on demand.") { Button("Clear") { Task { await act("faces", "Face crops cleared; they are remade as needed.") } } }
                item("Search index", st.dbl("index"), "Rebuilt from digiKam's database in seconds.") { EmptyView() }
                item("\(m.str("appName") ?? "iopix") database", st.dbl("viewerDb"), st.str("viewerDbError").map { "MySQL/MariaDB is configured but could not be used (\($0)), so the SQLite file is in use. Fix the cause in Settings and restart." } ?? "Users, albums, favorites, settings, AI results.") { EmptyView() }
                item("Content embeddings", st.dbl("embeddings"), "The content-search index.") { EmptyView() }
                item("AI models", st.dbl("models"), nil) { EmptyView() }
                item("Sidecar backups", st.dbl("backups"), "Each sidecar as it was before it was first changed.") { EmptyView() }
                item("Image file backups", st.dbl("fileBackups"), "The original of each file whose metadata was rewritten.") { EmptyView() }
                item("Database backups", st.dbl("dbBackups"), "digiKam's database before each write (the last 10).") { EmptyView() }
                item("Deleted photos", st.dbl("deletedPhotos"), "Copies of deleted photos and their sidecars, kept until you remove them (data/deleted-photos).") { EmptyView() }
            } header: { Text("\(AdminFormat.bytes(st.dbl("free"))) free on the disk") } footer: {
                Text("Backups are never deleted automatically (apart from keeping the last ten database copies); remove them by hand on the server once you are happy with the changes.")
            }
            Section {
                Button(downloading == "digikam" ? "Preparing…" : "digiKam database") { Task { await fetch("api/backup/digikam", "digikam-backup", tag: "digikam") } }
                Button(downloading == "app" ? "Preparing…" : "\(m.str("appName") ?? "iopix") data (zip)") { Task { await fetch("api/backup/app", "iopix-data.zip", tag: "app") } }
            } header: { Text("Download a backup") } footer: {
                Text("digiKam's database as it is right now (a consistent copy, or a mysqldump for MariaDB), and \(m.str("appName") ?? "iopix")'s data as a zip. Keep them somewhere else, such as Files or iCloud Drive.")
            }
            .disabled(downloading != nil)
        }
        .navigationTitle("Storage and backups")
        .sheet(item: $sharing, onDismiss: { if let s = sharing { try? FileManager.default.removeItem(at: s.url.deletingLastPathComponent()) } }) { f in
            ShareSheet(items: [f.url])
        }
        .adminConfirm($confirm)
        .adminNotice(notice)
    }

    private func item<B: View>(_ label: String, _ size: Double?, _ detail: String?, @ViewBuilder action: () -> B) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.body.weight(.medium))
                Spacer()
                Text(AdminFormat.bytes(size)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            action().font(.subheadline).buttonStyle(.borderless)
        }
    }

    private func act(_ a: String, _ done: String) async {
        await notice.run(done) {
            try await AdminAPI.post("api/maintenance", ["action": a])
            await changed()
            fresh = (try? await AdminAPI.get("api/maintenance")) ?? fresh
        }
    }

    private func fetch(_ path: String, _ name: String, tag: String) async {
        downloading = tag
        defer { downloading = nil }
        do { sharing = AdminSharedFile(url: try await AdminAPI.download(path, fallbackName: name)) } catch { notice.fail(error) }
    }
}

// MARK: - Server log

struct AdminLogScreen: View {
    @State private var level = "any"
    @State private var contains = ""
    @State private var requests = false
    @State private var lines: [String] = []
    @State private var info = ""
    @State private var note: String?
    @State private var sharing: AdminSharedFile?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("Show", selection: $level) {
                    Text("Everything").tag("any"); Text("Warnings").tag("warning"); Text("Errors").tag("error"); Text("Sign-ins").tag("auth")
                }
                .pickerStyle(.segmented)
                HStack {
                    TextField("Filter, e.g. sync or a file name", text: $contains).textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { Task { await load() } }
                    Toggle("Requests", isOn: $requests).toggleStyle(.button).font(.caption)
                }
            }
            .padding(12)
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 1) {
                        if lines.isEmpty { Text(loading ? "Loading…" : (note ?? "Nothing matches.")).foregroundStyle(.secondary) }
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                            Text(l).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(l.contains(" ERROR ") ? .red : l.contains(" WARNING ") ? .orange : .primary)
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: lines.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
            }
            .background(Color(.secondarySystemBackground))
            Text(info).font(.caption2).foregroundStyle(.secondary).padding(6)
        }
        .navigationTitle("Server log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh")
                Button {
                    Task {
                        do { sharing = AdminSharedFile(url: try await AdminAPI.download("api/log/download", fallbackName: "server.log")) } catch { info = "Couldn't download the log: \(error.localizedDescription)" }
                    }
                } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Download the log")
            }
        }
        .task(id: "\(level)|\(requests)") { await load() }
        .sheet(item: $sharing, onDismiss: { if let s = sharing { try? FileManager.default.removeItem(at: s.url.deletingLastPathComponent()) } }) { ShareSheet(items: [$0.url]) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await AdminAPI.get("api/log", [URLQueryItem(name: "lines", value: "500"), URLQueryItem(name: "level", value: level),
                                                       URLQueryItem(name: "requests", value: requests ? "1" : "0"),
                                                       URLQueryItem(name: "contains", value: contains.trimmingCharacters(in: .whitespaces))])
            lines = r.strings("lines")
            note = r.str("note")
            info = "\((r.str("file") ?? "") as NSString).lastPathComponent · \(AdminFormat.bytes(r.dbl("size_bytes"))) · the last \(AdminFormat.n(r.int("returned"))) lines"
        } catch {
            lines = []
            note = error.localizedDescription
        }
    }
}

// MARK: - Version and updates

/// Which version runs on the server and whether a newer one is out: check, update now (then wait for the restart),
/// and the MCP update token.
struct AdminUpdateRow: View {
    let appName: String
    @StateObject private var notice = AdminNotice()
    @State private var u: [String: Any] = [:]
    @State private var confirm: AdminConfirm?
    @State private var token: [String: Any]?
    @State private var waiting: String?
    @State private var poll: Task<Void, Never>?
    @State private var gone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AdminRow(title: "\(appName) version", detail: "“Update now” installs the newest version, keeps your settings and data, and restarts \(appName).")
            Text(waiting ?? stateText).font(.footnote).foregroundStyle(u.dict("progress").str("error") != nil ? .red : .secondary)
            if let last = lastText { Text(last).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 16) {
                Button("Check for updates") {
                    Task { await notice.run(nil) { try await AdminAPI.post("api/update", ["action": "check"]) }; await load() }
                }
                Button("MCP token…") {
                    Task { do { token = try await AdminAPI.post("api/update", ["action": "token"]) } catch { notice.fail(error) } }
                }
            }
            .buttonStyle(.borderless)
            if u.bool("docker") {
                Text("Docker: update by pulling the image (docker compose pull && docker compose up -d).").font(.caption).foregroundStyle(.secondary)
            } else if u.bool("canRun") {
                Button("Update now") {
                    confirm = AdminConfirm(title: "Update \(appName) now?", message: "The newest version is fetched, the packages refreshed and \(appName) restarted.", button: "Update") { await run() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(u.dict("check").str("status") != "update" || u.dict("progress").bool("running"))
            }
        }
        .task { await load() }
        .onAppear { gone = false }
        .onDisappear { gone = true; poll?.cancel() }
        .alert("MCP update token", isPresented: Binding(get: { token != nil }, set: { if !$0 { token = nil } }), presenting: token) { t in
            Button("Copy") { UIPasteboard.general.string = t.str("token") }
            if !t.bool("fromEnv") {
                Button("Regenerate", role: .destructive) {
                    confirm = AdminConfirm(title: "Generate a new token?", message: "The old one stops working.", button: "Regenerate", destructive: true) {
                        await notice.run("New token made.") { try await AdminAPI.post("api/update", ["action": "regenerate_token"]) }
                    }
                }
            }
            Button("Close", role: .cancel) {}
        } message: { t in
            Text("\(t["mcpEnabled"] != nil && !t.bool("mcpEnabled") ? "The MCP server is switched off (Settings › MCP server), so this token is not usable until it is turned on.\n\n" : "")\(t.str("token") ?? "")\n\nAn MCP client (e.g. Claude) can run the update with the update_viewer tool and this token; treat it like a password.\(t.bool("fromEnv") ? " Set by MCP_ADMIN_TOKEN in the environment." : "")")
        }
        .adminConfirm($confirm)
        .adminNotice(notice)
    }

    private var stateText: String {
        let c = u.dict("check"), p = u.dict("progress"), v = u.str("version") ?? "?"
        if u.isEmpty { return "Loading…" }
        if p.bool("running") { return "Updating… \(appName) restarts when it is done." }
        if let e = p.str("error") { return "Last update failed: \(e)" }
        switch c.str("status") {
        case nil: return "v\(v)"
        case "current": return "v\(v) is the latest version."
        case "update":
            let msg = c.str("remoteMessage").map { m -> String in
                let trimmed = m.replacingOccurrences(of: #"^v\d+\.\d+\.\d+:\s*"#, with: "", options: .regularExpression)
                return ": \(trimmed)"
            } ?? ""
            return "You have v\(v); \(c.str("remoteVersion").map { "v\($0)" } ?? "a newer build") is available\(c.str("remoteDate").map { " (\($0))" } ?? "")\(msg)"
        default: return "Could not check: \(c.str("error") ?? "")"
        }
    }

    private var lastText: String? {
        let p = u.dict("progress"), last = u.dict("lastUpdate")
        guard !p.bool("running"), p.str("error") == nil, let t = last.str("text") else { return nil }
        return "Last update: \(t)"
    }

    private func load() async {
        u = (try? await AdminAPI.get("api/update")) ?? u
        poll?.cancel()
        if gone || Task.isCancelled { return }
        if u.dict("progress").bool("running") {
            poll = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if !Task.isCancelled { await load() } }
        }
    }

    /// Starts the update and waits (up to three minutes) for the server to come back with another version.
    private func run() async {
        let was = await versionKey()
        do { try await AdminAPI.post("api/update", ["action": "run"]) } catch { notice.fail(error); return }
        waiting = "Updating… \(appName) restarts when it is done."
        let until = Date().addingTimeInterval(180)
        while Date() < until {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if gone { waiting = nil; return }  // the screen is gone; the server restarts on its own
            if let now = await versionKey(), now != was {
                waiting = nil
                notice.say("Updated to v\(now.split(separator: "|").first ?? "").")
                await load()
                return
            }
        }
        waiting = "The update did not finish; check the version again in a moment."
    }

    private func versionKey() async -> String? {
        guard let s = try? await AdminAPI.get("api/status"), let v = s.str("appVersion") else { return nil }
        return "\(v)|\(s.str("commit") ?? "")"
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
