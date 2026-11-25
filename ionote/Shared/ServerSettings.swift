import SwiftUI

/// Settings for the ioNote server, the same on the Mac and on iPhone/iPad: signing in (the suite's one sign-in for
/// apps, DeviceSignInForm) and how syncing is going.
struct ServerSettings: View {
    @EnvironmentObject private var store: NotesStore

    var body: some View {
        Section {
            if let c = store.client.credential {
                LabeledContent("Server") { Text(c.base.absoluteString).textSelection(.enabled) }
                LabeledContent("Signed in as") {
                    Text([store.account?.name ?? c.name, store.account?.role].compactMap { $0 }.joined(separator: ", "))
                }
                if let account = store.account, !account.canWrite {
                    Text("This account can read notes but not change them.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Sign Out", role: .destructive) { Task { await store.signOut() } }
            } else {
                Text("Not signed in.").foregroundStyle(.secondary)
                Button("Sign In…") { store.showingSignIn = true }
            }
        } header: {
            Text("ioNote server")
        } footer: {
            Text("Your notes, folders, tags and colours sync with this server. A copy stays on this device, so you can read, search and write while offline.")
                .font(.caption).foregroundStyle(.secondary)
        }

        if store.client.credential != nil {
            Section {
                LabeledContent("Status") {
                    Text(store.syncSummary)
                }
                if let problem = store.syncProblem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let last = store.lastSync {
                    LabeledContent("Last synced") {
                        Text(last.formatted(date: .abbreviated, time: .standard))
                    }
                }
                Button("Sync Now") { Task { await store.sync() } }
                    .disabled(store.syncStatus == .syncing)
            } header: {
                Text("Sync")
            }
        }
    }
}

/// The sign-in form in a sheet or window of its own.
struct SignInSheet: View {
    @EnvironmentObject private var store: NotesStore

    var body: some View {
        NavigationStack {
            DeviceSignInForm(app: ServerConfig.app, onSignedIn: { store.signedIn($0) }, onCancel: { store.showingSignIn = false })
                .navigationTitle("Sign In to ioNote")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 480, idealHeight: 540)
        #endif
        .onAppear {
            // a device that signed in the old way (a cookie) still knows the address: fill it in
            let st = ServerConfig.store
            if st.lastAddress == nil, let old = ServerConfig.serverURL { st.remember(address: old.absoluteString, name: "") }
        }
    }
}

extension View {
    /// The sign-in form as a sheet (store.showingSignIn): opened from Settings, and again when the server stops
    /// taking this device's app password (401). Attached to the top of a view, not to a row of its form: a sheet on a
    /// row closes by itself as soon as the form redraws.
    func signInSheet(_ store: NotesStore, when shown: Bool = true) -> some View {
        sheet(isPresented: Binding(get: { shown && store.showingSignIn }, set: { store.showingSignIn = $0 })) {
            SignInSheet()
                .environmentObject(store)
        }
    }
}

/// How syncing with the server is going, for the sidebar.
struct SyncStatusView: View {
    @EnvironmentObject private var store: NotesStore

    var body: some View {
        Label(store.syncSummary, systemImage: symbol)
            .help(store.syncProblem ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var symbol: String {
        switch store.syncStatus {
        case .synced: return store.pendingChanges > 0 ? "arrow.triangle.2.circlepath.icloud" : "checkmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .offline, .notConfigured: return "icloud.slash"
        case .signedOut, .failed: return "exclamationmark.icloud"
        }
    }
}
