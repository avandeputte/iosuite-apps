import SwiftUI

/// Settings › Account › App passwords, as every io app has them: one per app or device, used with the user name
/// instead of the password; made here (shown once), listed and revoked (/api/auth/app-passwords).
struct AdminAppPasswordsSection: View {
    @StateObject private var notice = AdminNotice()
    @State private var items: [[String: Any]] = []
    @State private var label = ""
    @State private var made: String?
    @State private var confirm: AdminConfirm?

    var body: some View {
        Section {
            ForEach(Array(items.enumerated()), id: \.offset) { _, p in
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.str("label") ?? "").font(.body.weight(.medium))
                    Text("Made \(AdminFormat.when(p.dbl("created"))) · last used \(p.dbl("lastUsed") == nil ? "never" : AdminFormat.when(p.dbl("lastUsed")))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Revoke", role: .destructive) { revoke(p) }
                }
                .contextMenu { Button("Revoke", role: .destructive) { revoke(p) } }
            }
            if items.isEmpty { Text("No app passwords yet.").foregroundStyle(.secondary) }
            TextField("Name, e.g. Alex’s iPhone", text: $label)
            Button("New app password") {
                Task {
                    await notice.run(nil) {
                        let name = label.trimmingCharacters(in: .whitespaces)
                        let r = try await AdminAPI.post("api/auth/app-passwords", ["label": name.isEmpty ? "Device" : name, "scope": ""])
                        made = r.str("password")
                        label = ""
                        await load()
                    }
                }
            }
            if let made {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Copy it now, it is shown only once:").font(.footnote.weight(.semibold))
                    Text(made).font(.body.monospaced()).textSelection(.enabled)
                    Button("Copy") { UIPasteboard.general.string = made }.buttonStyle(.borderless)
                }
            }
        } header: { Text("App passwords") } footer: {
            Text("One per app or device, used with your user name instead of your password. Revoke one without touching the others.")
        }
        .task { await load() }
        .adminConfirm($confirm)
        .adminNotice(notice)
    }

    private func revoke(_ p: [String: Any]) {
        let name = p.str("label") ?? ""
        confirm = AdminConfirm(title: "Revoke “\(name)”?", message: "Whatever uses it stops signing in.", button: "Revoke", destructive: true) {
            await notice.run("Revoked “\(name)”.") {
                try await AdminAPI.delete("api/auth/app-passwords/\(p.int("id") ?? 0)")
                await load()
            }
        }
    }

    private func load() async {
        items = (try? await AdminAPI.get("api/auth/app-passwords"))?.list("items") ?? items
    }
}
