import SwiftUI

/// Settings › Server, as every io app has it (iosuite-shared's /api/server): the MCP switch, the version with
/// check, update and the daily check, the server's facts, the log and Restart; then ioPix's backups to download.
struct AdminServerScreen: View {
    @ObservedObject var model: AdminModel
    @StateObject private var notice = AdminNotice()
    @State private var s: [String: Any] = [:]
    @State private var problem: String?
    @State private var confirm: AdminConfirm?
    @State private var waiting: String?
    @State private var poll: Task<Void, Never>?
    @State private var gone = false
    @State private var sharing: AdminSharedFile?
    @State private var downloading: String?

    private var appName: String { model.appName }

    var body: some View {
        Form {
            if let problem, s.isEmpty {
                Section { Text("Couldn't load the server: \(problem)").foregroundStyle(.secondary) }
            } else if s.isEmpty {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else {
                mcp
                version
                about
                Section {
                    NavigationLink { AdminLogScreen() } label: {
                        AdminRow(title: "Server log", detail: "What the server has been doing: edits, database writes, updates, background jobs and errors.")
                    }
                    Button("Restart \(appName)", role: .destructive) {
                        confirm = AdminConfirm(title: "Restart \(appName) now?", message: "Anyone using it is disconnected for a few seconds.", button: "Restart", destructive: true) {
                            await notice.run("Restarting…") { try await AdminAPI.post("api/server", ["action": "restart"]) }
                        }
                    }
                } footer: { Text("Restart stops the server; launchd, Docker or systemd starts it again within seconds.") }
            }
            backups
        }
        .navigationTitle("Server")
        .task { await load() }
        .refreshable { await load() }
        .onAppear { gone = false }
        .onDisappear { gone = true; poll?.cancel() }
        .sheet(item: $sharing, onDismiss: { if let f = sharing { try? FileManager.default.removeItem(at: f.url.deletingLastPathComponent()) } }) { ShareSheet(items: [$0.url]) }
        .adminConfirm($confirm)
        .adminNotice(notice)
    }

    @ViewBuilder private var mcp: some View {
        if s["mcpEnabled"] != nil {
            Section {
                Toggle("MCP server", isOn: Binding(get: { s.bool("mcpEnabled") || s.bool("mcpLocked") }, set: { on in
                    Task { await notice.run(on ? "The MCP server at /mcp is on." : "The MCP server is off: /mcp does not answer.") { s = try await AdminAPI.post("api/server", ["mcpEnabled": on]) } }
                }))
                .disabled(s.bool("mcpLocked"))
            } header: { Text("MCP server") } footer: {
                Text(s.bool("mcpLocked") ? "Switched on by MCP=1 in the environment." : "\(s.str("mcpAbout") ?? "") Assistants sign in with an app password (Settings › Account).")
            }
        }
    }

    private var version: some View {
        Section {
            Text(waiting ?? stateText).foregroundStyle(s.dict("progress").str("error") != nil ? .red : .primary)
            if let last = lastText { Text(last).font(.footnote).foregroundStyle(.secondary) }
            Button("Check for updates") {
                Task { await notice.run(nil) { try await AdminAPI.post("api/server", ["action": "check"]) }; await load() }
            }
            if s.bool("docker") {
                Text("Docker: update by pulling the image (docker compose pull && docker compose up -d).").font(.footnote).foregroundStyle(.secondary)
            } else if s.bool("canRun") {
                Button("Update now") {
                    confirm = AdminConfirm(title: "Update \(appName) now?", message: "The newest version is fetched, the packages refreshed and \(appName) restarted.", button: "Update") { await run() }
                }
                .disabled(s.dict("check").str("status") != "update" || s.dict("progress").bool("running") || waiting != nil)
            }
            Toggle("Check daily", isOn: Binding(get: { s.bool("autoCheck") }, set: { on in
                Task { await notice.run(on ? "\(appName) will check for updates once a day." : "\(appName) will not contact GitHub on its own.") { s = try await AdminAPI.post("api/server", ["autoCheck": on]) } }
            }))
            .disabled(s.bool("autoCheckLocked"))
        } header: { Text("\(appName) version") } footer: {
            Text(s.bool("autoCheckLocked") ? "The daily check is switched off by UPDATE_CHECK=0 in the environment."
                 : "“Update now” installs the newest version, keeps your settings and data, and restarts \(appName). The daily check only fetches the public list of changes from GitHub.")
        }
    }

    /// The facts the app adds about itself (info()["about"]: [[label, value], ...]), when it has any.
    @ViewBuilder private var about: some View {
        let rows = (s["about"] as? [[Any]] ?? []).compactMap { r -> (String, String)? in
            guard r.count == 2, let l = r[0] as? String else { return nil }
            return (l, (r[1] as? String) ?? (r[1] as? NSNumber)?.stringValue ?? "")
        }
        if !rows.isEmpty {
            Section("This server") {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in AdminRow(title: r.0) { Text(r.1).foregroundStyle(.secondary).multilineTextAlignment(.trailing) } }
            }
        }
    }

    private var backups: some View {
        let noDigikam = model.m.dict("digikam").bool("none")
        return Section {
            if !noDigikam {
                Button(downloading == "digikam" ? "Preparing…" : "digiKam database") { Task { await fetch("api/backup/digikam", "digikam-backup", tag: "digikam") } }
            }
            Button(downloading == "app" ? "Preparing…" : "\(appName) data (zip)") { Task { await fetch("api/backup/app", "iopix-data.zip", tag: "app") } }
        } header: { Text("Backups") } footer: {
            Text(noDigikam ? "\(appName)’s database and search index, as a zip." : "digiKam’s database as it is now, and \(appName)’s database and search index as a zip.")
        }
        .disabled(downloading != nil)
    }

    private var stateText: String {
        let c = s.dict("check"), p = s.dict("progress"), v = s.str("version") ?? "?"
        if p.bool("running") { return "Updating… \(appName) restarts when it is done." }
        if let e = p.str("error") { return "Last update failed: \(e)" }
        switch c.str("status") {
        case nil: return "v\(v)"
        case "current": return "v\(v) is the latest version."
        case "update":
            let msg = c.str("remoteMessage").map { ": " + $0.replacingOccurrences(of: #"^v\d+\.\d+\.\d+:\s*"#, with: "", options: .regularExpression) } ?? ""
            return "You have v\(v); \(c.str("remoteVersion").map { "v\($0)" } ?? "a newer build") is available\(c.str("remoteDate").map { " (\($0))" } ?? "")\(msg)"
        default: return "v\(v). Could not check: \(c.str("error") ?? "")"
        }
    }

    private var lastText: String? {
        let p = s.dict("progress"), last = s.dict("lastUpdate")
        guard !p.bool("running"), p.str("error") == nil, let t = last.str("text") else { return nil }
        return "Last update: \(t)"
    }

    private func load() async {
        do {
            s = try await AdminAPI.get("api/server")
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        poll?.cancel()
        if gone || Task.isCancelled { return }
        if s.dict("progress").bool("running") {
            poll = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if !Task.isCancelled { await load() } }
        }
    }

    /// Starts the update and waits (up to three minutes) for the server to come back with another version.
    private func run() async {
        let was = await versionKey()
        do { try await AdminAPI.post("api/server", ["action": "update"]) } catch { notice.fail(error); return }
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
        guard let st = try? await AdminAPI.get("api/status"), let v = st.str("version") else { return nil }
        return "\(v)|\(st.str("commit") ?? "")"
    }

    private func fetch(_ path: String, _ name: String, tag: String) async {
        downloading = tag
        defer { downloading = nil }
        do { sharing = AdminSharedFile(url: try await AdminAPI.download(path, fallbackName: name)) } catch { notice.fail(error) }
    }
}

// MARK: - Server log

/// Settings › Server › Server log: the tail of the log, filtered by level or text.

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

