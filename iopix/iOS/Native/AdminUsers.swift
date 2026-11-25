import SwiftUI

/// Settings › Security: whether visitors must sign in to ioPix. The suite's accounts, their roles and the sign-in at a
/// reverse proxy are the start page's Settings › People, one place for every app.
struct AdminUsersScreen: View {
    @ObservedObject var model: AdminModel
    @StateObject private var notice = AdminNotice()
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
                Text("Visitors see only the sign-in screen; nothing from the library (not even thumbnails) is served without an account. Accounts and their roles are managed in the start page's Settings › People.")
            }
        }
        .navigationTitle("Security")
        .task { requireLogin = model.status.bool("requireLogin") }
        .adminNotice(notice)
    }
}
