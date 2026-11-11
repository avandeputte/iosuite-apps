import SwiftUI

/// Settings for the ionote server, the same on the Mac and on iPhone/iPad: its address, signing in,
/// the optional Cloudflare service token, and how syncing is going.
struct ServerSettings: View {
    @EnvironmentObject private var store: NotesStore
    @State private var address = ServerConfig.serverURL?.absoluteString ?? ""
    @State private var addressProblem: String?
    @State private var checking = false
    @State private var tokenID = ServiceToken.clientID ?? ""
    @State private var tokenSecret = ""
    @State private var hasToken = ServiceToken.isSet

    var body: some View {
        Section {
            TextField("Server", text: $address, prompt: Text("192.168.1.10:8610 or notes.example.net"))
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit(connect)
            HStack {
                Button(checking ? "Checking…" : "Connect", action: connect)
                    .disabled(checking || ServerConfig.normalisedServer(address)?.absoluteString == ServerConfig.serverURL?.absoluteString)
                if ServerConfig.serverURL != nil {
                    Button("Disconnect", role: .destructive) {
                        address = ""
                        store.setServer(nil)
                    }
                }
            }
            if let addressProblem {
                Text(addressProblem).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("ionote server")
        } footer: {
            Text("Your notes, folders, tags and colours sync with this server. A copy stays on this device, so you can read, search and write while offline.")
                .font(.caption).foregroundStyle(.secondary)
        }

        if ServerConfig.serverURL != nil {
            Section("Account") {
                if let account = store.account {
                    LabeledContent("Signed in as") {
                        Text([account.name, account.role].compactMap { $0 }.joined(separator: ", "))
                    }
                    if !account.canWrite {
                        Text("This account can read notes but not change them.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Sign Out") { Task { await store.signOut() } }
                } else {
                    Text("Sign in on the server's own page, the way you do in the browser.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Sign In…") { store.showingSignIn = true }
                }
            }

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

            Section {
                TextField("Client ID", text: $tokenID)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField(hasToken ? "Client secret (saved)" : "Client secret", text: $tokenSecret)
                HStack {
                    Button("Save Token") {
                        store.setServiceToken(id: tokenID, secret: tokenSecret)
                        tokenSecret = ""
                        hasToken = ServiceToken.isSet
                    }
                    .disabled(tokenID.isEmpty || tokenSecret.isEmpty)
                    if hasToken {
                        Button("Remove", role: .destructive) {
                            store.setServiceToken(id: nil, secret: nil)
                            tokenID = ""
                            tokenSecret = ""
                            hasToken = false
                        }
                    }
                }
            } header: {
                Text("Cloudflare Access")
            } footer: {
                Text("Only needed when the server sits behind Cloudflare Access: a service token lets ionote through. It is kept in the Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func connect() {
        guard let url = ServerConfig.normalisedServer(address) else {
            addressProblem = "That doesn't look like a server address."
            return
        }
        checking = true
        addressProblem = nil
        Task {
            let problem = await store.client.probe(url)
            checking = false
            if let problem {
                addressProblem = problem
            } else {
                address = url.absoluteString
                store.setServer(url)
                await store.refreshAccount()
                if store.account == nil { store.showingSignIn = true }  // straight on to the server's sign-in page
            }
        }
    }
}

extension View {
    /// The server's sign-in page as a sheet, opened by ServerSettings (store.showingSignIn). Attached to the top of the
    /// Settings view, not to a row of its form: a sheet on a row closes by itself as soon as the form redraws, which a
    /// sign-in does at once (the page sets cookies, the account is checked).
    func signInSheet(_ store: NotesStore) -> some View {
        sheet(isPresented: Binding(get: { store.showingSignIn }, set: { store.showingSignIn = $0 })) {
            SignInView()
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
