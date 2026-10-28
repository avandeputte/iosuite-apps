import SwiftUI

/// Maintenance › Damaged files (iopix 1.86): every photo's file read and checked, and the one safe repair (a JPEG whose
/// picture is complete but whose end marker is missing gets the marker, after a copy is kept; undo in the edit log).
struct AdminDamagedScreen: View {
    let canEdit: Bool
    @StateObject private var notice = AdminNotice()
    @State private var d: [String: Any] = [:]
    @State private var loaded = false
    @State private var problem: String?
    @State private var confirm: AdminConfirm?
    @State private var viewer: PagerStart?
    @State private var poll: Task<Void, Never>?

    private var found: [[String: Any]] { d.list("found") }
    private var fixable: [Int] { found.filter { $0.bool("fixable") }.compactMap { $0.int("photo") } }
    private var progress: [String: Any] { d.dict("progress") }

    var body: some View {
        List {
            Section {
                Text("Every photo's file is read and checked: JPEGs that stop early or lack their end marker, PNGs with damaged data, and pictures that cannot be decoded. Files are only read. A JPEG whose picture is complete but whose end marker is missing (some phones' burst photos) can be repaired: the marker is added after a copy of the file is kept. A JPEG whose bottom is missing can be cropped to the intact part above the damage. Both are in the edit log with undo. A backup or the original device may still have a damaged file whole.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let problem { Text(problem).foregroundStyle(.secondary) }
                if loaded {
                    Text(statusText)
                    if !progress.bool("running") {
                        Button((d.int("checked") ?? 0) < (d.int("total") ?? 0) ? "Check the files" : "Check new files") { Task { await run(redo: false) } }
                        Button("Check everything again") {
                            confirm = AdminConfirm(title: "Check all \(AdminFormat.n(d.int("total"))) photos again from the start?", message: "Every file is read once more.", button: "Check again") { await run(redo: true) }
                        }
                    }
                    if canEdit && fixable.count > 1 {
                        Button("Repair all \(fixable.count)") { ask(fixable) }
                    }
                    if d["jpegtran"] != nil && !d.bool("jpegtran") {
                        Text("jpegtran is not installed on the server, so a JPEG missing its end marker cannot be checked for completeness or repaired (see Maintenance › Lossless JPEG edits).")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } else if problem == nil {
                    ProgressView()
                }
            }
            if !found.isEmpty {
                Section("Damaged files") {
                    ForEach(Array(found.enumerated()), id: \.offset) { i, x in
                        HStack(alignment: .top, spacing: 12) {
                            Button { viewer = PagerStart(list: PhotoList(ids: found.compactMap { $0.int("photo") }), index: i) } label: {
                                RemoteImage(path: "thumb/\(x.int("photo") ?? 0)").frame(width: 64, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(x.str("name") ?? "").font(.body.weight(.semibold)).lineLimit(2)
                                Text(x.str("folder") ?? "").font(.caption).foregroundStyle(.secondary)
                                Text(x.str("detail") ?? "").font(.caption).foregroundStyle(x.bool("fixable") ? Color.secondary : Color.orange)
                                if canEdit && x.bool("fixable"), let id = x.int("photo") {
                                    Button("Repair") { ask([id]) }.font(.callout)
                                }
                                // iopix 1.87: a JPEG whose bottom is missing can be cropped to the part above the damage
                                if canEdit, let keep = x.dbl("keep"), let id = x.int("photo") {
                                    Button("Keep the intact part (\(Int((keep * 100).rounded()))%)") { askKeep(id, keep) }.font(.callout)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Damaged files")
        .task { await load() }
        .refreshable { await load() }
        .onDisappear { poll?.cancel() }
        .pager($viewer)
        .adminConfirm($confirm)
        .adminNotice(notice)
    }

    private var statusText: String {
        let p = progress
        if p.bool("running") {
            return "Checking… \(AdminFormat.n(p.int("done"))) / \(AdminFormat.n(p.int("total"))) files, \(AdminFormat.plural(p.int("found") ?? 0, "problem")) so far."
        }
        let checked = d.int("checked") ?? 0
        let last = p.dbl("finished").map { " (last run \(AdminFormat.when($0)))" } ?? ""
        let what = !found.isEmpty ? " \(AdminFormat.plural(found.count, "damaged file")) found." : checked > 0 ? " Nothing damaged found." : ""
        return "\(AdminFormat.n(checked)) of \(AdminFormat.n(d.int("total"))) photos checked\(last).\(what)"
    }

    private func load() async {
        do {
            d = try await AdminAPI.get("api/filecheck")
            problem = nil
        } catch let e as URLError where e.code == .cancelled {
            return
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
        poll?.cancel()
        if progress.bool("running") {
            poll = Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if !Task.isCancelled { await load() } }
        }
    }

    private func run(redo: Bool) async {
        await notice.run(nil) {
            let r = try await AdminAPI.post("api/filecheck/run", ["redo": redo])
            let n = r.int("queued") ?? 0
            notice.say(n > 0 ? "Checking \(AdminFormat.plural(n, "file")) in the background." : "Every file is checked already.")
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await load()
    }

    private func askKeep(_ id: Int, _ keep: Double) {
        confirm = AdminConfirm(title: "Crop this photo to its intact part?",
                               message: "It keeps the top \(Int((keep * 100).rounded()))% of the picture, above the damage, without re-encoding. The file is copied first and the crop can be undone from the edit log.",
                               button: "Crop") {
            await notice.run(nil) {
                let r = try await AdminAPI.post("api/filecheck/keep", ["ids": [id]])
                let failed = r.list("failed")
                notice.say(failed.isEmpty ? "Cropped to the intact part." : "Not cropped: \(failed[0].str("error") ?? "")")
                ImageCache.shared.forget("thumb/\(id)"); ImageCache.shared.forget("preview/\(id)")
                NotificationCenter.default.post(name: .iopixPhotosChanged, object: nil)
            }
            await load()
        }
    }

    private func ask(_ ids: [Int]) {
        confirm = AdminConfirm(title: "Add the missing end marker to \(AdminFormat.plural(ids.count, "file"))?",
                               message: "Each file is copied first and the change can be undone from the edit log.", button: "Repair") {
            await notice.run(nil) {
                let r = try await AdminAPI.post("api/filecheck/repair", ["ids": ids])
                let done = (r["repaired"] as? [Any])?.count ?? 0
                let failed = r.list("failed")
                notice.say("\(AdminFormat.plural(done, "file")) repaired\(failed.isEmpty ? "" : "; \(failed.count) not: \(failed[0].str("error") ?? "")").")
                NotificationCenter.default.post(name: .iopixPhotosChanged, object: nil)
            }
            await load()
        }
    }
}
