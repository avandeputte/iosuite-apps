import SwiftUI

/// Users and sign-in: whether visitors must sign in, the accounts (role, password, email, person, sign-in list),
/// adding one, and sign-in at a reverse proxy.
struct AdminUsersScreen: View {
    @ObservedObject var model: AdminModel
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var notice = AdminNotice()
    @State private var users: [[String: Any]] = []
    @State private var roles: [String] = ["viewer", "editor", "admin"]
    @State private var adding = false
    @State private var requireLogin = false

    var body: some View {
        List {
            Section {
                Toggle("Require sign-in", isOn: Binding(get: { requireLogin }, set: { on in
                    requireLogin = on
                    Task {
                        await notice.run(on ? "Visitors now have to sign in." : "Visitors can browse again.") {
                            do { try await AdminAPI.post("api/settings", ["require_login": on]) } catch { requireLogin = !on; throw error }
                            await model.load()
                        }
                    }
                }))
            } footer: {
                Text("Visitors see only the sign-in screen; nothing from the library (not even thumbnails) is served without an account. Viewers keep settings, favorites and albums; editors can also change the library; admins can also change settings, run maintenance and manage users.")
            }
            Section("Accounts") {
                ForEach(Array(users.enumerated()), id: \.offset) { _, u in
                    NavigationLink {
                        AdminUserScreen(user: u, roles: roles, isMe: u.int("id") == model.user.int("id"), appName: model.appName) { await load() }
                    } label: {
                        HStack(spacing: 12) {
                            avatar(u)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(u.str("name") ?? "") + Text(u.int("id") == model.user.int("id") ? "  (you)" : "").foregroundStyle(.secondary)
                                Text([u.str("role")?.capitalized, u.bool("passwordless") ? "one-click" : nil, u.str("email").flatMap { $0.isEmpty ? nil : $0 }]
                                        .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button { adding = true } label: { Label("Add user", systemImage: "person.badge.plus") }
            }
            Section {
                NavigationLink("Sign-in at a proxy") { AdminProxyScreen() }
            } footer: {
                Text("Someone signed in at your reverse proxy (Cloudflare Access, Authelia, Authentik, oauth2-proxy) is signed in here too, matched to an account by email, then name.")
            }
        }
        .navigationTitle("Users and sign-in")
        .task { requireLogin = model.status.bool("requireLogin"); await load() }
        .refreshable { await load() }
        .sheet(isPresented: $adding) { AdminAddUserSheet(roles: roles) { name in notice.say("Added \(name)."); Task { await load() } } }
        .adminNotice(notice)
    }

    @ViewBuilder private func avatar(_ u: [String: Any]) -> some View {
        if let pid = u.int("person"), let p = store.people.first(where: { $0.id == pid }) {
            FaceImage(person: p).frame(width: 36, height: 36).clipShape(Circle())
        } else {
            Text(String((u.str("name") ?? "?").prefix(1)).uppercased())
                .font(.headline).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(Hue.indigo, in: Circle())
        }
    }

    private func load() async {
        guard let d = try? await AdminAPI.get("api/users") else { return }
        users = d.list("users")
        let r = d.strings("roles")
        if !r.isEmpty { roles = r }
    }
}

/// One account: email, who they are in People, role, password, whether the sign-in screen offers them, delete.
struct AdminUserScreen: View {
    let user: [String: Any]
    let roles: [String]
    let isMe: Bool
    let appName: String
    let changed: () async -> Void
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var notice = AdminNotice()
    @State private var email = ""
    @State private var role = "viewer"
    @State private var password = ""
    @State private var listed = true
    @State private var person: Int?
    @State private var passwordless = false
    @State private var picking = false
    @State private var confirm: AdminConfirm?

    private var id: Int { user.int("id") ?? 0 }
    private var name: String { user.str("name") ?? "" }

    var body: some View {
        Form {
            Section("Email") {
                TextField("Email (optional)", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save email") { update(["email": email.trimmingCharacters(in: .whitespaces)], "Email saved.") }
            }
            Section("Person in People") {
                HStack {
                    if let p = person.flatMap({ pid in store.people.first { $0.id == pid } }) {
                        FaceImage(person: p).frame(width: 36, height: 36).clipShape(Circle())
                        Text(p.name)
                    } else {
                        Text("Not linked").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(person == nil ? "Link" : "Change") { picking = true }
                }
                if person != nil {
                    Button("Unlink", role: .destructive) { update(["person": NSNull()], "Unlinked.", then: { person = nil }) }
                }
            }
            Section {
                Picker("Role", selection: Binding(get: { role }, set: { r in
                    let old = role
                    role = r
                    update(["role": r], "\(name) is now \(r).", fail: { role = old })
                })) {
                    ForEach(roles, id: \.self) { Text($0.capitalized).tag($0) }
                }
            } footer: { Text("Viewers browse and keep favorites and albums; editors can also change the library; admins can also change settings and users.") }
            Section {
                Text(passwordless ? "No password: one-click sign-in from the account picker." : "Password set.").font(.footnote).foregroundStyle(.secondary)
                SecureField("New password (8 characters or more)", text: $password).textContentType(.newPassword)
                Button("Set password") { update(["password": password], "Password set.", then: { password = ""; passwordless = false }) }
                    .disabled(password.count < 8)
                if role == "viewer" && !passwordless {
                    Button("Remove the password") {
                        confirm = AdminConfirm(title: "Remove \(name)'s password?", message: "Anyone who can reach \(appName) can then sign in as \(name) with one click.", button: "Remove", destructive: true) {
                            update(["password": ""], "Password removed.", then: { passwordless = true })
                        }
                    }
                }
            } header: { Text("Password") }
            Section {
                Toggle("Offered on the sign-in screen", isOn: Binding(get: { listed }, set: { on in
                    listed = on
                    update(["listed": on], on ? "\(name) is offered on the sign-in screen again." : "\(name) is no longer offered; “Other” and the name still sign in.", fail: { listed = !on })
                }))
            } footer: { Text("Unticked, \(name) signs in through “Other”, by name\(passwordless ? "" : " and password").") }
            if !isMe {
                Section {
                    Button("Delete \(name)", role: .destructive) {
                        confirm = AdminConfirm(title: "Delete the user \(name)?", message: "Their favorites, albums and settings go with the account.", button: "Delete", destructive: true) {
                            await notice.run(nil) {
                                try await AdminAPI.post("api/users/\(id)", ["delete": true])
                                await changed()
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(name)
        .onAppear {
            email = user.str("email") ?? ""
            role = user.str("role") ?? "viewer"
            listed = user["listed"] as? Bool ?? (user["listed"] as? NSNumber)?.boolValue ?? true
            person = user.int("person")
            passwordless = user.bool("passwordless")
        }
        .sheet(isPresented: $picking) {
            AdminPersonPicker(title: "Who is \(name)?") { p in
                update(["person": p.map { $0.id as Any } ?? NSNull()], "Linked to \(p?.name ?? "nobody").", then: { person = p?.id })
            }
        }
        .adminConfirm($confirm)
        .adminNotice(notice)
    }

    private func update(_ body: [String: Any], _ done: String, fail: (() -> Void)? = nil, then: (() -> Void)? = nil) {
        Task {
            do {
                try await AdminAPI.post("api/users/\(id)", body)
                then?()
                notice.say(done)
                await changed()
            } catch {
                fail?()
                notice.fail(error)
            }
        }
    }
}

struct AdminAddUserSheet: View {
    let roles: [String]
    let added: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var role = "viewer"
    @State private var noPassword = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("User name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Email (optional)", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Toggle("No password (one-click sign-in, viewer only)", isOn: $noPassword)
                    if !noPassword { SecureField("Password", text: $password).textContentType(.newPassword) }
                    Picker("Role", selection: $role) { ForEach(roles, id: \.self) { Text($0.capitalized).tag($0) } }
                        .disabled(noPassword)
                }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .navigationTitle("Add user")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: noPassword) { _, on in if on { role = "viewer"; password = "" } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Cancel") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        Task {
                            do {
                                try await AdminAPI.post("api/users", ["name": n, "email": email.trimmingCharacters(in: .whitespaces),
                                                                    "password": noPassword ? "" : password, "role": noPassword ? "viewer" : role])
                                added(n); dismiss()
                            } catch { problem = error.localizedDescription }
                        }
                    } label: { BarText("Add") }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (!noPassword && password.isEmpty))
                }
            }
        }
    }
}

/// Sign-in at a reverse proxy: which proxy, Cloudflare's team domain and AUD tag, the user header, the proxy's
/// addresses, and what happens to someone with no account here.
struct AdminProxyScreen: View {
    @StateObject private var notice = AdminNotice()
    @State private var d: [String: Any] = [:]
    @State private var v: [String: String] = [:]

    private static let keys = ["AUTH_PROXY", "CF_ACCESS_TEAM", "CF_ACCESS_AUD", "AUTH_PROXY_HEADER", "AUTH_PROXY_TRUSTED", "AUTH_PROXY_CREATE"]
    private var env: Set<String> { Set(d.strings("fromEnv")) }
    private var mode: String { (v["AUTH_PROXY"] ?? "").lowercased().adminIfEmpty("off") }

    var body: some View {
        Form {
            if !d.isEmpty {
                Section {
                    Text(stateText).font(.footnote.weight(.semibold))
                    if !env.isEmpty { Text("Set in iopix.env (change them there): \(env.sorted().joined(separator: ", "))").font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    Picker("Proxy", selection: field("AUTH_PROXY", "off")) {
                        Text("Off").tag("off"); Text("Cloudflare Access").tag("cloudflare"); Text("HAProxy").tag("haproxy")
                        Text("nginx").tag("nginx"); Text("Caddy").tag("caddy"); Text("Traefik").tag("traefik"); Text("Another proxy").tag("header")
                    }
                    .disabled(env.contains("AUTH_PROXY"))
                } footer: { Text("Which reverse proxy signs people in. Everyone else still uses the sign-in here; requests from outside through Cloudflare can only use accounts with a password.") }
                if mode == "cloudflare" {
                    Section {
                        text("CF_ACCESS_TEAM", "myteam.cloudflareaccess.com")
                        text("CF_ACCESS_AUD", "Application Audience (AUD) tag")
                        let seen = d.dict("seen")
                        if let iss = seen.str("iss") {
                            let aud = (seen["aud"] as? [Any])?.compactMap { $0 as? String }.first ?? seen.str("aud") ?? ""
                            Text("Last request through your tunnel: team \(iss.replacingOccurrences(of: "https://", with: "")), AUD \(aud)\(seen.str("email").map { ", \($0)" } ?? "").").font(.footnote).foregroundStyle(.secondary)
                            if !env.contains("CF_ACCESS_TEAM") && !env.contains("CF_ACCESS_AUD") {
                                Button("Use these") { v["CF_ACCESS_TEAM"] = iss.replacingOccurrences(of: "https://", with: ""); v["CF_ACCESS_AUD"] = aud }
                            }
                        }
                    } header: { Text("Cloudflare") } footer: {
                        Text("Team domain: Zero Trust › Settings › Team name and domain. AUD tag: Zero Trust › Access › Applications › this app › Overview. With both set, the token Cloudflare signs is checked and the email comes from it.")
                    }
                }
                if mode != "off" {
                    Section {
                        text("AUTH_PROXY_HEADER", "Default: " + (mode == "cloudflare" ? "Cf-Access-Authenticated-User-Email" : "Remote-User, X-Forwarded-User…"))
                        text("AUTH_PROXY_TRUSTED", "Default: 127.0.0.1, ::1")
                        Picker("Someone with no account here", selection: field("AUTH_PROXY_CREATE", "")) {
                            Text("Gets the sign-in screen").tag(""); Text("Is denied access").tag("deny")
                            Text("Gets a viewer account").tag("viewer"); Text("Gets an editor account").tag("editor")
                        }
                        .disabled(env.contains("AUTH_PROXY_CREATE"))
                    } header: { Text("Header and addresses") } footer: {
                        Text("The user header is the request header the proxy puts the signed-in user in (comma-separate several); it is believed only from the proxy addresses.")
                    }
                }
                Section {
                    Button("Save") {
                        var body: [String: Any] = [:]
                        for k in Self.keys where !env.contains(k) { body[k] = (v[k] ?? "").trimmingCharacters(in: .whitespaces) }
                        Task { await notice.run("Proxy sign-in saved.") { try await AdminAPI.post("api/settings/proxy", body); await load() } }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Sign-in at a proxy")
        .task { await load() }
        .adminNotice(notice)
    }

    private var stateText: String {
        switch d.str("mode") ?? "off" {
        case "off": return "Off: only the sign-in here."
        case "cloudflare": return d.bool("cloudflareVerified") ? "On: Cloudflare Access tokens are verified." : "On, but without the team domain and AUD tag: the header is believed from the proxy addresses only."
        case let m: return "On (\(m)): the user header is believed from \(d.strings("trusted").joined(separator: ", "))."
        }
    }

    private func field(_ k: String, _ fallback: String) -> Binding<String> {
        Binding(get: { (v[k] ?? "").isEmpty ? fallback : (v[k] ?? "").lowercased() }, set: { v[k] = $0 })
    }

    private func text(_ k: String, _ prompt: String) -> some View {
        TextField(prompt, text: Binding(get: { v[k] ?? "" }, set: { v[k] = $0 }))
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .disabled(env.contains(k))
    }

    private func load() async {
        guard let r = try? await AdminAPI.get("api/settings/proxy") else { return }
        d = r
        let vals = r.dict("values")
        v = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, vals.str($0) ?? "") })
    }
}
