import SwiftUI

/// What the settings screens read from the server: the account (/api/auth/me), the server's state (/api/status)
/// and, for admins, everything Maintenance knows (/api/maintenance).
@MainActor
final class AdminModel: ObservableObject {
    @Published var me: [String: Any] = [:]
    @Published var status: [String: Any] = [:]
    @Published var m: [String: Any] = [:]
    @Published var loaded = false
    @Published var problem: String?

    var user: [String: Any] { me.dict("user") }
    var signedIn: Bool { me.bool("signedIn") }
    var isAdmin: Bool { me.bool("isAdmin") || status.bool("isAdmin") }
    var usersExist: Bool { me.bool("usersExist") || status.bool("usersExist") }
    var editing: Bool { status.bool("editing") }
    var appName: String { status.str("appName") ?? m.str("appName") ?? "iopix" }
    var version: String { status.str("appVersion") ?? "?" }
    /// The account's display settings (theme, units, badges, info_hide), kept on the server for signed-in people.
    var prefs: [String: Any] { me.dict("settings") }

    func load() async {
        do {
            async let a = AdminAPI.get("api/auth/me")
            async let b = AdminAPI.get("api/status")
            me = try await a
            status = try await b
            m = (try? await AdminAPI.get("api/maintenance")) ?? m  // everyone gets the counts; admins the paths and storage too
            // the app's colors follow the account's theme (IopixApp reads it from UserDefaults)
            if signedIn, let t = prefs.str("theme") { UserDefaults.standard.set(t, forKey: "iopix.pref.theme") }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    /// A display setting: saved with the account when signed in (so it follows to the web app and other devices),
    /// on this device otherwise.
    func pref(_ key: String, _ fallback: String) -> String {
        if signedIn, let v = prefs.str(key) { return v }
        return UserDefaults.standard.string(forKey: "iopix.pref.\(key)") ?? fallback
    }

    func setPref(_ key: String, _ value: String) async throws {
        UserDefaults.standard.set(value, forKey: "iopix.pref.\(key)")
        guard signedIn else { return }
        _ = try await AdminAPI.post("api/auth/settings", [key: value])
        var s = prefs
        s[key] = value
        me["settings"] = s
    }
}

/// Settings, as the web app groups them: your account and display for everyone; the server, editing, AI and
/// users for admins. Maintenance and About sit at the end.
struct AdminSettingsScreen: View {
    @StateObject private var model = AdminModel()
    @StateObject private var notice = AdminNotice()
    @EnvironmentObject private var queue: UploadQueue
    @State private var setup = false

    var body: some View {
        List {
            if let p = model.problem, !model.loaded || model.me.isEmpty {
                Section { Text("Couldn't load the settings: \(p)").foregroundStyle(.secondary) }
            }
            if model.loaded && !model.usersExist {
                Section {
                    AdminRow(title: "No users yet",
                             detail: "\(model.appName) is open to anyone who can reach it. Create the admin account to switch on sign-in: visitors then browse read-only, and only editors and admins can change the library.") {
                        EmptyView()
                    }
                    Button("Create the admin account") { setup = true }
                }
            }
            Section {
                NavigationLink { AdminAccountScreen(model: model) } label: {
                    Label(model.signedIn ? "\(model.user.str("name") ?? "Account") · \(model.user.str("role") ?? "")" : "Account", systemImage: "person.crop.circle")
                }
                NavigationLink { AdminDisplayScreen(model: model) } label: { Label("Display", systemImage: "paintbrush") }
            }
            if model.isAdmin {
                Section("Admin") {
                    NavigationLink { AdminServerScreen(model: model) } label: { Label("digiKam and server", systemImage: "server.rack") }
                    if model.editing {
                        NavigationLink { AdminEditingScreen(model: model) } label: { Label("Editing", systemImage: "pencil") }
                    }
                    NavigationLink { AdminAISettingsScreen(model: model) } label: { Label("AI and search", systemImage: "sparkles") }
                    if model.usersExist {
                        NavigationLink { AdminUsersScreen(model: model) } label: { Label("Users and sign-in", systemImage: "person.2") }
                    }
                    NavigationLink { AdminMaintenanceScreen() } label: { Label("Maintenance", systemImage: "wrench.and.screwdriver") }
                }
            }
            #if targetEnvironment(macCatalyst)
            Section {
                NavigationLink { MacSettingsScreen() } label: { Label("Mac", systemImage: "desktopcomputer") }
            }
            #endif
            Section {
                NavigationLink { AdminAboutScreen(model: model) } label: { Label("About \(model.appName)", systemImage: "info.circle") }
            }
        }
        .navigationTitle("Settings")
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(isPresented: $setup) {
            AdminSetupSheet {  // signed in as the new admin now: the rest of the app should know
                Task {
                    await model.load()
                    await queue.refreshAccount()
                    NotificationCenter.default.post(name: .iopixReload, object: nil)
                }
            }
        }
        .adminNotice(notice)
    }
}

// MARK: - Account

struct AdminAccountScreen: View {
    @ObservedObject var model: AdminModel
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var queue: UploadQueue
    @StateObject private var notice = AdminNotice()
    @State private var current = ""
    @State private var newPassword = ""
    @State private var picking = false
    @State private var confirm: AdminConfirm?

    private var role: String { model.user.str("role") ?? "" }
    private var person: Person? { model.user.int("person").flatMap { id in store.people.first { $0.id == id } } }

    var body: some View {
        List {
            if !model.signedIn {
                Section {
                    Text("Not signed in. Sign in from the Photos tab's web page or the sign-in screen to keep favorites, albums and settings with an account.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    AdminRow(title: model.user.str("name") ?? "", detail: roleText) { Text(role.capitalized).foregroundStyle(.secondary) }
                    AdminRow(title: "Signed in", detail: signedInText)
                }
                Section("Who you are in People") {
                    HStack {
                        if let person {
                            FaceImage(person: person).frame(width: 40, height: 40).clipShape(Circle())
                            Text(person.name)
                        } else {
                            Text("Not linked").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isAdmin { Button(person == nil ? "Link to a person" : "Change") { picking = true } }
                    }
                    if !model.isAdmin && person == nil {
                        Text("An admin can link your account in Settings › Users.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let person {
                        Button("Photos of me") { router.open("#/photos?tag=\(person.id)") }
                    }
                }
                if !model.me.bool("viaProxy") {
                    Section("Change password") {
                        SecureField("Current password", text: $current).textContentType(.password)
                        SecureField("New password (8 characters or more)", text: $newPassword).textContentType(.newPassword)
                        Button("Change password") {
                            Task {
                                await notice.run("Password changed.") {
                                    try await AdminAPI.post("api/auth/password", ["current": current, "password": newPassword])
                                    current = ""; newPassword = ""
                                }
                            }
                        }
                        .disabled(current.isEmpty || newPassword.count < 8)
                    }
                }
                if model.me.str("signedInBy") != "proxy" {
                    Section {
                        Button("Sign out everywhere else") {
                            confirm = AdminConfirm(title: "Sign out everywhere else?",
                                                   message: "Every other browser and phone signed in as \(model.user.str("name") ?? "you") will have to sign in again. This one stays signed in.",
                                                   button: "Sign out everywhere") {
                                await notice.run("Signed out everywhere else.") { try await AdminAPI.post("api/auth/logout_all") }
                            }
                        }
                        Button(model.me.str("signedInBy") == "cloudflare" && model.me.bool("throughCloudflare") ? "Sign out (of Cloudflare too)" : "Sign out", role: .destructive) {
                            Task {
                                await IopixClient.shared.signOut()
                                await CookieSync.clearWebView()
                                await queue.refreshAccount()
                                NotificationCenter.default.post(name: .iopixReload, object: nil)
                                await model.load()
                                await store.load()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Account")
        .sheet(isPresented: $picking) {
            AdminPersonPicker(title: "Who are you?") { p in
                Task {
                    await notice.run("Linked to \(p?.name ?? "nobody").") {
                        try await AdminAPI.post("api/auth/person", ["person": p.map { $0.id as Any } ?? NSNull()])
                        await model.load()
                    }
                }
            }
        }
        .adminConfirm($confirm)
        .adminNotice(notice)
    }

    private var roleText: String {
        switch role {
        case "admin": return "You can change the library, the settings and the users."
        case "editor": return "You can change the library (edits, tags, faces, places)."
        default: return "You can browse, and keep favorites, albums and display settings."
        }
    }

    private var signedInText: String {
        switch model.me.str("signedInBy") {
        case "cloudflare": return model.me.bool("throughCloudflare") ? "Through Cloudflare Access, from outside your network." : "Through Cloudflare Access; this device stays signed in on your home network too."
        case "proxy": return "At the sign-in page of your proxy; sign out there."
        case "oneclick": return "Here, with one click (no password)."
        default: return "Here, with a password."
        }
    }
}

/// Create the first account (an admin), which switches on sign-in.
struct AdminSetupSheet: View {
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Admin user name", text: $name).textContentType(.username).autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("Password (8 characters or more)", text: $password).textContentType(.newPassword)
                } footer: {
                    Text("Once an admin exists, visitors browse read-only, signed-in users keep their settings on the server, and only editors and admins can change the library or the settings.")
                }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .navigationTitle("Create the admin account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Cancel") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            do {
                                _ = try await AdminAPI.post("api/auth/setup", ["name": name.trimmingCharacters(in: .whitespaces), "password": password])
                                done(); dismiss()
                            } catch { problem = error.localizedDescription }
                        }
                    } label: { BarText("Create") }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || password.count < 8)
                }
            }
        }
    }
}

// MARK: - Display

struct AdminDisplayScreen: View {
    @ObservedObject var model: AdminModel
    @StateObject private var notice = AdminNotice()
    @State private var appName = ""
    @State private var provider = "osm"
    @State private var mapsKey = ""
    @State private var serverKey = ""

    static let infoSections: [(String, String)] = [
        ("caption", "Title and caption"), ("date", "Date and time"), ("file", "File name, size and folder"), ("people", "People"), ("tags", "Tags"),
        ("location", "Location and map"), ("details", "Details: rating, creator, copyright, video"), ("camera", "Camera, lens and exposure"),
        ("ai", "AI analysis: detected content, objects, text, sharpness"), ("history", "Edit log: every change, with undo"),
    ]

    private var keptWith: String { model.signedIn ? "Saved with your account, so it follows you to the web app and other devices." : "Kept on this device; sign in to keep it with an account." }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: binding("theme", "system")) {
                    Text("Light").tag("light"); Text("Dark").tag("dark"); Text("System").tag("system")
                }
            } footer: { Text("Light (the default) or dark colors, or follow the device's setting. \(keptWith)") }
            Section {
                Picker("Units", selection: binding("units", "auto")) {
                    Text("Automatic (\(Locale.current.measurementSystem == .us ? "miles" : "kilometres") here)").tag("auto")
                    Text("Miles").tag("mi"); Text("Kilometres").tag("km")
                }
            } footer: { Text("How distances and heights read: the size of an approximate location, a day's trail, altitude. \(keptWith)") }
            Section {
                Toggle("Show badges", isOn: Binding(get: { model.pref("badges", "1") != "0" }, set: { on in save("badges", on ? "1" : "0") }))
            } header: { Text("Thumbnail badges") } footer: { Text("The small marks on thumbnails: face tags, GPS coordinates and favorites.") }
            Section {
                ForEach(Self.infoSections, id: \.0) { key, label in
                    Toggle(label, isOn: Binding(get: { !hidden.contains(key) }, set: { on in
                        var h = hidden
                        if on { h.remove(key) } else { h.insert(key) }
                        save("info_hide", h.sorted().joined(separator: ","))
                    }))
                }
            } header: { Text("Info panel") } footer: { Text("The sections the photo info panel shows. \(keptWith)") }
            if model.isAdmin {
                Section {
                    TextField("iopix", text: $appName)
                    Button("Save name") {
                        Task { await notice.run("Name saved.") { try await AdminAPI.post("api/settings", ["app_name": appName]); await model.load() } }
                    }
                } header: { Text("Name") } footer: { Text("What \(model.appName) calls itself, for everyone: the top bar, the browser tab and the installed app. Leave it empty for iopix.") }
                Section {
                    Picker("Map provider", selection: $provider) {
                        Text("OpenStreetMap (no account needed)").tag("osm")
                        Text("Google Maps (your API key)").tag("google")
                    }
                    if provider == "google" {
                        SecureField(model.m.bool("googleMapsKeySet") ? "Key is set; paste a new one to replace it" : "Google Maps API key", text: $mapsKey)
                        SecureField(model.m.bool("googleServerKeySet") ? "Server key is set; paste a new one to replace it" : "Server key (optional)", text: $serverKey)
                    }
                    Button("Save map provider") {
                        if provider == "google" && mapsKey.isEmpty && !model.m.bool("googleMapsKeySet") { notice.say("Enter the Google Maps API key first.", error: true); return }
                        var body: [String: Any] = ["map_provider": provider]
                        if !mapsKey.trimmingCharacters(in: .whitespaces).isEmpty { body["google_maps_key"] = mapsKey.trimmingCharacters(in: .whitespaces) }
                        if !serverKey.trimmingCharacters(in: .whitespaces).isEmpty { body["google_server_key"] = serverKey.trimmingCharacters(in: .whitespaces) }
                        Task { await notice.run("Map provider saved.") { try await AdminAPI.post("api/settings", body); mapsKey = ""; serverKey = ""; await model.load() } }
                    }
                } header: { Text("Maps") } footer: {
                    Text("Maps and place search use \(model.m.str("mapProvider") == "google" && model.m.bool("googleMapsKeySet") ? "Google Maps" : "OpenStreetMap") in the web app. Google needs an API key with the Map Tiles and Geocoding APIs and billing on. An optional second key, restricted to this server's address, is used for what the server calls. Keys are never shown again.")
                }
            }
        }
        .navigationTitle("Display")
        .onAppear {
            appName = model.m.str("appNameSet") ?? ""
            provider = model.m.str("mapProvider") ?? "osm"
        }
        .adminNotice(notice)
    }

    private var hidden: Set<String> { Set(model.pref("info_hide", "").split(separator: ",").map(String.init).filter { !$0.isEmpty }) }

    private func binding(_ key: String, _ fallback: String) -> Binding<String> {
        Binding(get: { model.pref(key, fallback) }, set: { save(key, $0) })
    }

    private func save(_ key: String, _ value: String) {
        Task { await notice.run(nil) { try await model.setPref(key, value) } }
    }
}

// MARK: - digiKam and server

struct AdminServerScreen: View {
    @ObservedObject var model: AdminModel
    @StateObject private var notice = AdminNotice()
    @State private var confirm: AdminConfirm?
    @State private var db = DBForm()
    @State private var dbResult: String?
    @State private var roots: [[String: Any]] = []
    @State private var rootEdits: [String: String] = [:]
    @State private var viewer: [String: Any] = [:]
    @State private var vdb = DBForm()
    @State private var vCopy = true
    @State private var vDrop = false
    @State private var vResult: String?
    @State private var mergePlan: String?

    struct DBForm {
        var type = "sqlite", sqliteDir = "", host = "", port = "", database = "", user = "", password = "", backup = "auto"
        var payload: [String: Any] {
            ["type": type, "sqlite_dir": sqliteDir, "host": host, "port": port, "database": database, "user": user, "password": password, "backup": backup]
        }
        init() {}
        init(_ d: [String: Any]) {
            type = d.str("type") == "mysql" ? "mysql" : "sqlite"
            sqliteDir = d.str("sqlite_dir") ?? ""; host = d.str("host") ?? ""; port = d.str("port") ?? ""
            database = d.str("database") ?? ""; user = d.str("user") ?? ""; backup = d.str("backup") == "skip" ? "skip" : "auto"
        }
    }

    private var d: [String: Any] { model.m.dict("database") }
    private var dk: [String: Any] { model.m.dict("digikam") }

    var body: some View {
        Form {
            digikamDatabase
            albumRoots
            viewerDatabase
            Section {
                Toggle("Check daily", isOn: Binding(get: { model.m.bool("updateCheck") }, set: { on in
                    Task { await notice.run(on ? "\(model.appName) will check for updates once a day." : "\(model.appName) will not contact GitHub on its own.") { try await AdminAPI.post("api/settings", ["update_check": on]); await model.load() } }
                }))
                .disabled(model.m.bool("updateCheckLocked"))
            } header: { Text("Check for updates daily") } footer: {
                Text(model.m.bool("updateCheckLocked") ? "Switched off by UPDATE_CHECK=0 in the environment: \(model.appName) never contacts GitHub on its own."
                     : "Once a day \(model.appName) asks GitHub whether a newer version exists and, if so, tells admins. Only the public list of changes is fetched; nothing about this install or its photos is sent.")
            }
            if model.m["mcpEnabled"] != nil {  // iopix 1.85 and later
                Section {
                    Toggle("MCP server", isOn: Binding(get: { model.m.bool("mcpEnabled") || model.m.bool("mcpLocked") }, set: { on in
                        Task { await notice.run(on ? "The MCP server at /mcp is on." : "The MCP server is off: /mcp does not answer.") { try await AdminAPI.post("api/settings", ["mcp_enabled": on]); await model.load() } }
                    }))
                    .disabled(model.m.bool("mcpLocked"))
                } header: { Text("MCP server") } footer: {
                    Text(model.m.bool("mcpLocked") ? "Switched on by MCP=1 in the environment."
                         : "The endpoint at /mcp that lets an AI assistant (Claude, for example) search and read this library. Off: /mcp does not answer at all. With Require sign-in on, an assistant must also send the admin token.")
                }
            }
            Section {
                Toggle("Read-only", isOn: Binding(get: { model.m.bool("readOnly") }, set: { on in
                    Task { await notice.run(on ? "Read-only mode on." : "Read-only mode off.") { try await AdminAPI.post("api/settings", ["read_only": on]); await model.load() } }
                }))
                .disabled(model.m.bool("readOnlyLocked"))
            } header: { Text("Read-only mode") } footer: {
                Text(model.m.bool("readOnlyLocked") ? "Locked on by READ_ONLY=1 in the environment: nothing in the library can be changed from \(model.appName)."
                     : "When on, \(model.appName) only browses: editing, tagging, face naming, place tags, GPS tracks, metadata sync and database updates are refused by the server. Favorites and albums keep working.")
            }
            digikamSync
        }
        .navigationTitle("digiKam and server")
        .task {
            db = DBForm(d)
            await loadRoots()
            await loadViewer()
            if dk.bool("conflict") {
                if let p = try? await AdminAPI.get("api/library/merge") {
                    mergePlan = (p.int("total") ?? 0) > 0 ? "To merge: " + p.strings("summary").joined(separator: ", ") + "." : "Nothing to merge."
                }
            }
        }
        .adminConfirm($confirm)
        .adminNotice(notice)
    }

    private var digikamDatabase: some View {
        Section {
            Picker("Type", selection: $db.type) {
                Text("SQLite (digikam4.db file)").tag("sqlite"); Text("MySQL / MariaDB").tag("mysql")
            }
            if db.type == "sqlite" {
                TextField("Folder with digikam4.db", text: $db.sqliteDir).autocorrectionDisabled().textInputAutocapitalization(.never)
            } else {
                TextField("Host", text: $db.host).autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Port", text: $db.port).keyboardType(.numberPad)
                TextField("Database", text: $db.database).autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("User", text: $db.user).autocorrectionDisabled().textInputAutocapitalization(.never)
                SecureField(d.bool("password_set") ? "Password (stored; leave empty to keep)" : "Password", text: $db.password)
            }
            Picker("Backups", selection: $db.backup) {
                Text("Before deleting photos or a tag, or a merge").tag("auto")
                Text("Never (backed up elsewhere)").tag("skip")
            }
            Button("Test connection") {
                dbResult = "Testing…"
                Task {
                    do {
                        let r = try await AdminAPI.post("api/db/test", db.payload)
                        dbResult = "OK: \(AdminFormat.n(r.int("images"))) photos, \(AdminFormat.n(r.int("tags"))) tags, DBVersion \(r.str("dbVersion") ?? "?"), album root \(r.strings("roots").joined(separator: ", "))"
                    } catch { dbResult = error.localizedDescription }
                }
            }
            if let dbResult { Text(dbResult).font(.footnote).foregroundStyle(.secondary) }
            Button("Save and switch") {
                confirm = AdminConfirm(title: "Switch \(model.appName) to this digiKam database now?", message: "The index is rebuilt from it within seconds. \(model.appName)'s own data stays.", button: "Switch") {
                    await notice.run("Database settings saved; the index is rebuilding.") { try await AdminAPI.post("api/settings", ["database": db.payload]); try? await Task.sleep(nanoseconds: 2_500_000_000); await model.load() }
                }
            }
        } header: { Text("digiKam database") } footer: {
            Text("Currently \(d.str("type") == "mysql" ? "MySQL \(d.str("user") ?? "")@\(d.str("host") ?? ""):\(d.str("port") ?? "")/\(d.str("database") ?? "")" : "SQLite in \(d.str("sqlite_dir") ?? "?")"). Changing it rebuilds the index; \(model.appName)'s own data (favorites, albums, users, analysis) stays. Test first.")
        }
    }

    private var albumRoots: some View {
        Section {
            ForEach(Array(roots.enumerated()), id: \.offset) { _, r in
                let key = r.str("digikamPath") ?? ""
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.str("label") ?? "Album root").font(.body.weight(.medium))
                    Text("digiKam: \(key)").font(.caption).foregroundStyle(.secondary)
                    TextField(r.str("localPath") ?? "", text: Binding(get: { rootEdits[key] ?? "" }, set: { rootEdits[key] = $0 }))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    Text(r.bool("exists") ? "Found: \(r.str("localPath") ?? "") (\((r.int("sample") ?? 0) >= 2000 ? "2,000+" : AdminFormat.n(r.int("sample"))) files)" : "Not found: \(r.str("localPath") ?? "")")
                        .font(.caption).foregroundStyle(r.bool("exists") ? Color.secondary : Color.orange)
                }
            }
            Button("Check") { Task { await loadRoots() } }
            Button("Save album roots") {
                Task {
                    await notice.run("Album roots saved; the index is rebuilding.") {
                        try await AdminAPI.post("api/settings", ["album_roots": rootEdits.mapValues { $0.trimmingCharacters(in: .whitespaces) }])
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        await loadRoots()
                    }
                }
            }
        } header: { Text("Album roots") } footer: {
            Text("Where each album root digiKam knows is mounted on the server. Leave a field empty for the default; enter a path when the folder is mounted elsewhere, e.g. /photos in a container. Changing it rebuilds the index.")
        }
    }

    private var viewerDatabase: some View {
        Section {
            if viewer.isEmpty {
                ProgressView()
            } else {
                Text("Currently: \(viewer.str("type") == "mysql" ? "MySQL \(viewer.str("user") ?? "")@\(viewer.str("host") ?? ""):\(viewer.str("port") ?? "")/\(viewer.str("database") ?? "")" : "SQLite file \(viewer.str("sqlite_file") ?? "")")")
                    .font(.footnote)
                if let e = viewer.str("error"), !e.isEmpty {
                    Text("The configured MySQL database could not be used (\(e)); the SQLite file is in use meanwhile.").font(.footnote).foregroundStyle(.orange)
                }
                Picker("Type", selection: $vdb.type) {
                    Text("SQLite file").tag("sqlite"); Text("MySQL / MariaDB").tag("mysql")
                }
                if vdb.type == "mysql" {
                    TextField("Host", text: $vdb.host).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Port", text: $vdb.port).keyboardType(.numberPad)
                    TextField("Database", text: $vdb.database).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("User", text: $vdb.user).autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField(viewer.bool("password_set") ? "Password (stored; leave empty to keep)" : "Password", text: $vdb.password)
                }
                Toggle("Copy all the data to the new database", isOn: $vCopy)
                Toggle("Drop and recreate the tables there first", isOn: $vDrop)
                Button("Test connection") {
                    vResult = "Testing…"
                    Task {
                        do {
                            let r = try await AdminAPI.post("api/viewerdb/test", vdb.payload)
                            let t = r.dict("tables")
                            vResult = "OK: \(r.str("version") ?? ""). " + (t.isEmpty ? "No \(model.appName) tables there yet." : "Tables already there: " + t.map { "\($0.key) (\(AdminFormat.n(($0.value as? NSNumber)?.intValue)))" }.sorted().joined(separator: ", "))
                        } catch { vResult = error.localizedDescription }
                    }
                }
                Button("Switch") {
                    let target = vdb.type == "mysql" ? "MySQL \(vdb.user)@\(vdb.host):\(vdb.port)/\(vdb.database)" : "the SQLite file"
                    let what = vCopy ? "Every row is copied there first\(vDrop ? ", after dropping and recreating the tables at the target." : " (rows with the same ids are replaced).")"
                                     : "The data is NOT copied; \(model.appName) starts empty there unless the tables already hold data."
                    confirm = AdminConfirm(title: "Switch \(model.appName) to \(target)?", message: "\(what) \(model.appName) restarts when the copy is done.", button: "Switch", destructive: vDrop) {
                        vResult = "Copying… this can take a minute on a large library."
                        do {
                            var body = vdb.payload
                            body["copy"] = vCopy; body["drop"] = vDrop
                            let r = try await AdminAPI.post("api/viewerdb/switch", body)
                            vResult = "Switched to \(r.str("database") ?? ""): " + r.dict("copied").map { "\($0.key) \(AdminFormat.n(($0.value as? NSNumber)?.intValue))" }.sorted().joined(separator: ", ") + ". Restarting…"
                        } catch { vResult = error.localizedDescription }
                    }
                }
                if let vResult { Text(vResult).font(.footnote).foregroundStyle(.secondary) }
            }
        } header: { Text("\(model.appName) database") } footer: {
            Text("Where \(model.appName) keeps its own data: users, albums, favorites, settings, pending edits and the AI results. SQLite by default, or a MySQL/MariaDB database of its own. Switching copies every row across and restarts \(model.appName).")
        }
    }

    @ViewBuilder private var digikamSync: some View {
        Section {
            if dk.bool("conflict") {
                Text("On, but \(AdminFormat.plural(dk.int("localChanges") ?? 0, "change")) made while it was off \(dk.int("localChanges") == 1 ? "is" : "are") not in digiKam's database yet, so \(model.appName) keeps using its own library.")
                    .font(.footnote)
                if let mergePlan { Text(mergePlan).font(.footnote).foregroundStyle(.secondary) }
                Button("Merge into digiKam") {
                    confirm = AdminConfirm(title: "Write the changes into digiKam?", message: "Changes made while sync was off go into digiKam's database. digiKam must be closed; its database is backed up first.", button: "Merge") {
                        await notice.run(nil) {
                            let r = try await AdminAPI.post("api/library/merge")
                            let applied = r.dict("applied").map { "\(($0.value as? NSNumber)?.intValue ?? 0) \($0.key.replacingOccurrences(of: "_", with: " "))" }.sorted().joined(separator: ", ")
                            notice.say("Merged: \(applied.isEmpty ? "nothing to do" : applied)\((r.int("conflicts") ?? 0) > 0 ? "; \(r.int("conflicts")!) rows digiKam had also changed (the viewer's values won)" : "").")
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await model.load()
                        }
                    }
                }
                Button("Replace with digiKam's", role: .destructive) {
                    confirm = AdminConfirm(title: "Drop the changes made while sync was off?", message: "The library is copied from digiKam again. Edits in sidecars are kept.", button: "Replace", destructive: true) {
                        await notice.run("Copying the library from digiKam…") { try await AdminAPI.post("api/settings", ["library_replace": true]); try? await Task.sleep(nanoseconds: 2_500_000_000); await model.load() }
                    }
                }
                Button("Turn sync off") { Task { await notice.run("Sync off.") { try await AdminAPI.post("api/settings", ["digikam_sync": false]); await model.load() } } }
            } else {
                Toggle("Sync with digiKam", isOn: Binding(get: { dk.bool("sync") }, set: { on in
                    Task { await notice.run(on ? "Sync on." : "Sync off.") { try await AdminAPI.post("api/settings", ["digikam_sync": on]); await model.load() } }
                }))
                if dk.bool("sync") && !dk.bool("reachable") {
                    Text("digiKam's database is unreachable right now\(dk.str("error").map { ": \($0)" } ?? "").").font(.footnote).foregroundStyle(.orange)
                }
            }
        } header: { Text("Sync with digiKam") } footer: {
            let mirror = dk.dict("mirror")
            Text("On: \(model.appName) re-reads digiKam's database whenever digiKam saves, and writes edits into it whenever digiKam is closed. Off: \(model.appName) never opens digiKam's database; the library lives in its own tables (\(mirror.isEmpty ? "not taken yet" : "\(AdminFormat.n(mirror.int("photos"))) photos as of \(AdminFormat.when(mirror.dbl("taken")))")) and everything works there. Turning sync on again lets you choose what happens to changes made meanwhile.")
        }
    }

    private func loadRoots() async {
        guard let r = try? await AdminAPI.get("api/roots") else { return }
        roots = r.list("roots")
        rootEdits = Dictionary(roots.map { ($0.str("digikamPath") ?? "", $0.bool("overridden") ? ($0.str("localPath") ?? "") : "") }, uniquingKeysWith: { a, _ in a })
    }

    private func loadViewer() async {
        guard let v = try? await AdminAPI.get("api/viewerdb") else { return }
        viewer = v
        vdb = DBForm(v)
    }
}

// MARK: - Editing

struct AdminEditingScreen: View {
    @ObservedObject var model: AdminModel
    @StateObject private var notice = AdminNotice()
    @State private var placeTags: [String: Any]?
    @State private var templates: [Template] = []
    @State private var editing: Template?
    @State private var confirm: AdminConfirm?
    @State private var poll: Task<Void, Never>?

    struct Template: Identifiable, Equatable {
        var id = UUID()
        var name: String
        var fields: [String: String]
    }

    static let templateLabels: [(String, String)] = [
        ("creator", "Creator"), ("copyrightNotice", "Copyright notice"), ("rightsUsageTerms", "Usage terms"), ("creatorJobTitle", "Job title"),
        ("provider", "Credit"), ("source", "Source"), ("instructions", "Instructions"),
        ("creatorContactInfo.address", "Address"), ("creatorContactInfo.city", "City"), ("creatorContactInfo.provinceState", "State / province"),
        ("creatorContactInfo.postalCode", "Postal code"), ("creatorContactInfo.country", "Country"), ("creatorContactInfo.phone", "Phone"),
        ("creatorContactInfo.email", "Email"), ("creatorContactInfo.webUrl", "Web"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Also write into image files", isOn: Binding(get: { model.m.bool("writeFiles") }, set: { on in
                    Task { await notice.run(nil) { try await AdminAPI.post("api/settings", ["write_files": on]); await model.load() } }
                }))
            } header: { Text("Write metadata into image files") } footer: {
                Text("Off: edits go to XMP sidecars only. On: also into JPEG, PNG, TIFF and WebP files, like digiKam's “sidecar and file” mode.")
            }
            Section {
                Picker("New sidecars", selection: Binding(get: { model.m.bool("sidecarCompat") }, set: { on in
                    Task { await notice.run(nil) { try await AdminAPI.post("api/settings", ["sidecar_compat": on]); await model.load() } }
                })) {
                    Text("photo.jpg.xmp (digiKam's default)").tag(false)
                    Text("photo.xmp (compatible file name)").tag(true)
                }
            } header: { Text("Sidecar file names") } footer: { Text("Existing sidecars are read either way; pick what your digiKam is set to.") }
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
                    Button("Review place tags") { Task { placeTags = try? await AdminAPI.get("api/placetags") } }
                }
            } header: { Text("Place tags from GPS positions") } footer: {
                Text("Turns each geotagged photo's town into real digiKam tags under “Places/Country/Region/Town”, so places are searchable in digiKam too. Town names come from the offline place lookup and can be a neighboring town.")
            }
            Section {
                ForEach(templates) { t in
                    Button { editing = t } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).foregroundStyle(.primary)
                            Text(Self.templateLabels.compactMap { k, l in t.fields[k].flatMap { $0.isEmpty ? nil : "\(l): \($0)" } }.joined(separator: " · ").adminIfEmpty("empty"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            confirm = AdminConfirm(title: "Delete the template “\(t.name)”?", message: "Photos it was applied to are not changed.", button: "Delete", destructive: true) {
                                templates.removeAll { $0.id == t.id }
                                await saveTemplates()
                            }
                        }
                    }
                }
                Button { editing = Template(name: "", fields: [:]) } label: { Label("New template", systemImage: "plus") }
            } header: { Text("Metadata templates") } footer: {
                Text("Like digiKam's templates: creator, copyright, credit, source, instructions and contact details, applied to any selection in one go from the edit sheet.")
            }
        }
        .navigationTitle("Editing")
        .onAppear { templates = Self.parse(model.m["templates"]) }
        .onDisappear { poll?.cancel() }
        .sheet(item: $editing) { t in
            AdminTemplateSheet(template: t) { saved in
                if let i = templates.firstIndex(where: { $0.id == saved.id }) { templates[i] = saved } else { templates.append(saved) }
                Task { await saveTemplates() }
            }
        }
        .adminConfirm($confirm)
        .adminNotice(notice)
    }

    static func parse(_ raw: Any?) -> [Template] {
        (raw as? [[String: Any]] ?? []).map { t in
            Template(name: t.str("name") ?? "", fields: (t["fields"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String })
        }
    }

    private func saveTemplates() async {
        await notice.run("Templates saved.") {
            try await AdminAPI.post("api/settings", ["templates": templates.map { ["name": $0.name, "fields": $0.fields] }])
            await model.load()
            templates = Self.parse(model.m["templates"])
        }
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

struct AdminTemplateSheet: View {
    @State var template: AdminEditingScreen.Template
    let save: (AdminEditingScreen.Template) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Template name", text: $template.name) }
                Section {
                    ForEach(AdminEditingScreen.templateLabels, id: \.0) { key, label in
                        TextField(label, text: Binding(get: { template.fields[key] ?? "" }, set: { template.fields[key] = $0 }))
                    }
                }
            }
            .navigationTitle(template.name.isEmpty ? "New template" : template.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Cancel") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        template.name = template.name.trimmingCharacters(in: .whitespaces)
                        template.fields = template.fields.mapValues { $0.trimmingCharacters(in: .whitespaces) }
                        save(template)
                        dismiss()
                    } label: { BarText("Save") }
                    .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - AI and search (the preferences; the jobs and models are in Maintenance)

struct AdminAISettingsScreen: View {
    @ObservedObject var model: AdminModel
    @StateObject private var notice = AdminNotice()
    @State private var analysis: [String: Any] = [:]
    @State private var confirm: AdminConfirm?

    private var queue: [String: Any] { analysis.dict("queue") }

    var body: some View {
        Form {
            Section {
                let cores = queue.int("cores") ?? 4
                Picker("Cores per job", selection: Binding(get: { queue.int("threads") ?? 1 }, set: { n in
                    Task { await notice.run("Applies when the next job starts.") { try await AdminAPI.post("api/settings", ["bg_threads": n]); await load() } }
                })) {
                    ForEach(1...max(1, cores - 1), id: \.self) { Text("\($0)").tag($0) }
                }
                Text(queue.str("running").map { "Running: \(jobLabel($0))" } ?? "Idle").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Background work") } footer: {
                Text("Jobs run one at a time, in a fixed order, so \(model.appName) and other apps stay responsive. Each job may use up to this many of the server's \(queue.int("cores").map(String.init) ?? "?") cores.")
            }
            let models = analysis.list("models")
            let active = models.first { $0.bool("active") }
            let others = models.filter { $0.bool("installed") && !$0.bool("chosen") }
            Section {
                AdminRow(title: "In use", detail: nil) { Text(active?.str("label") ?? "none").foregroundStyle(.secondary) }
                ForEach(Array(others.enumerated()), id: \.offset) { _, o in
                    Button("Switch to \(o.str("label") ?? "")") {
                        confirm = AdminConfirm(title: "Switch content search to \(o.str("label") ?? "")?", message: "When that model has no index yet, the whole library is indexed again in the background; search stays on the current model until it finishes. You can switch back at any time.", button: "Switch") {
                            await notice.run("Switching to \(o.str("label") ?? "").") { try await AdminAPI.post("api/settings", ["search_model": o.str("key") ?? ""]); await load() }
                        }
                    }
                }
                NavigationLink("AI analysis and models") { AdminModelsScreen() }
            } header: { Text("Search model") } footer: {
                Text("Which model content search uses. More models, and the analysis jobs, are in Maintenance › AI analysis and models.")
            }
        }
        .navigationTitle("AI and search")
        .task { await load() }
        .adminConfirm($confirm)
        .adminNotice(notice)
    }

    private func load() async { analysis = (try? await AdminAPI.get("api/analysis")) ?? analysis }

    private func jobLabel(_ key: String) -> String {
        analysis.list("jobs").first { $0.str("key") == key || (key == "pixels" && $0.str("key") == "quality") }?.str("label") ?? key
    }
}

// MARK: - About

struct AdminAboutScreen: View {
    @ObservedObject var model: AdminModel
    @State private var update: [String: Any] = [:]

    var body: some View {
        List {
            Section("Server") {
                AdminRow(title: "Address") { Text(AppConfig.serverURL.host ?? AppConfig.serverURL.absoluteString).foregroundStyle(.secondary) }
                AdminRow(title: "\(model.appName) version") { Text("v\(model.version)").foregroundStyle(.secondary) }
                if let c = model.status.str("commit") { AdminRow(title: "Build") { Text(c).font(.body.monospaced()).foregroundStyle(.secondary) } }
                if !update.isEmpty { Text(updateText).font(.footnote).foregroundStyle(.secondary) }
                AdminRow(title: "Photos and videos") { Text(AdminFormat.n(model.m.int("photos"))).foregroundStyle(.secondary) }
            }
            Section("This app") {
                AdminRow(title: "Version") {
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                        .foregroundStyle(.secondary)
                }
            }
            if model.isAdmin {
                Section { NavigationLink("Check for updates in Maintenance") { AdminMaintenanceScreen() } }
            }
        }
        .navigationTitle("About")
        .task {
            if model.status.isEmpty { await model.load() }
            update = (try? await AdminAPI.get("api/update")) ?? [:]
        }
    }

    private var updateText: String {
        let c = update.dict("check")
        switch c.str("status") {
        case "current": return "This is the latest version."
        case "update": return "\(c.str("remoteVersion").map { "v\($0)" } ?? "A newer build") is available\(c.str("remoteDate").map { " (\($0))" } ?? "")."
        case nil: return "Not checked for updates yet."
        default: return "Couldn't check for updates\(c.str("error").map { ": \($0)" } ?? "")."
        }
    }
}

extension String {
    func adminIfEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
