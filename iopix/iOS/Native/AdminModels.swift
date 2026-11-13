import SwiftUI

/// Settings › AI › Analysis and models: every analysis job with its model, progress and actions; models without a
/// job (place names) after them.
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
    /// suggestions: MiVOLO) or the one chosen for its feature, as the web app lists them under Settings › AI.
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
        .navigationTitle("Analysis and models")
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
        return "Background work: \(running.map { "running \($0)" } ?? "idle"). Jobs run one at a time, in the order below, each with up to \(q.int("threads") ?? 1) of \(q.int("cores").map(String.init) ?? "?") cores (change that in Settings › AI).\((q["queued"] as? [Any])?.isEmpty == false ? " Waiting: \((q["queued"] as? [Any])?.count ?? 0)." : "")"
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
            + (stuck(j, since) ? " · probably stuck on that file: see the server log, or restart from Settings › Server" : "")
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

