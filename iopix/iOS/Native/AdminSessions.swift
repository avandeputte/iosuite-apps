import SwiftUI

/// Where the signed-in account is signed in (iopix 1.114 and later, /api/auth/sessions): every browser, phone and
/// app in every ioThing app, with where and how each began and was last seen. Swipe to end one; this device's own
/// session stays.
struct AdminSessionsScreen: View {
    @State private var sessions: [[String: Any]] = []
    @State private var problem: String?
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                Text("Every browser, phone and app signed in as you, in every ioThing app. Swipe a row to end that session; this device's own stays.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if loaded && sessions.isEmpty { Text(problem ?? "No sessions.").foregroundStyle(.secondary) }
                ForEach(sessions, id: \.sessionID) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(title(s)).font(.body.weight(s.bool("current") ? .semibold : .regular))
                            if s.bool("current") { Text("this device").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(detail(s)).font(.caption).foregroundStyle(.secondary)
                    }
                    .deleteDisabled(s.bool("current"))
                }
                .onDelete { offsets in Task { await end(offsets) } }
            }
        }
        .navigationTitle("Where you're signed in")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func title(_ s: [String: Any]) -> String {
        let app = s.str("app").map { $0 == "iopix" ? "ioPix" : $0 } ?? "?"
        let client = s.str("client") ?? "other"
        return "\(app) · \(client == "app" ? "the app" : client == "web" ? "a browser" : client)"
    }

    private func detail(_ s: [String: Any]) -> String {
        var parts: [String] = []
        if let ip = s.str("lastIp") ?? s.str("ip"), !ip.isEmpty { parts.append(ip) }
        if s.bool("cloudflare") { parts.append("through Cloudflare Access") }
        if let seen = when(s["lastSeen"]) { parts.append("last seen \(seen)") }
        else if let made = when(s["created"]) { parts.append("since \(made)") }
        return parts.joined(separator: " · ")
    }

    /// The server's times: seconds, or an ISO 8601 text.
    private func when(_ v: Any?) -> String? {
        if let n = v as? NSNumber { return AdminFormat.when(n.doubleValue) }
        guard let s = v as? String, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return AdminFormat.when(d.timeIntervalSince1970) }
        return s
    }

    private func load() async {
        do {
            sessions = try await AdminAPI.get("api/auth/sessions").list("sessions")
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    private func end(_ offsets: IndexSet) async {
        for i in offsets.sorted(by: >) {
            guard let id = sessions[i].str("id") else { continue }
            do {
                try await AdminAPI.delete("api/auth/sessions/\(id)")
                sessions.remove(at: i)
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    var sessionID: String { str("id") ?? "" }
}
