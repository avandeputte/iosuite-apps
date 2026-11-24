import SwiftUI

struct ContentView: View {
    @StateObject private var engine = SyncEngine.shared
    @State private var connectionCheck: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var enabledTypes = TypeSelection.allIDs.filter(TypeSelection.isEnabled).count

    var body: some View {
        NavigationStack {
            List {
                Section("Status") { status }

                if !engine.authorized {
                    Section {
                        Button("Allow access to Health data") { Task { await engine.authorize() } }
                            .disabled(engine.state == .authorizing)
                    } footer: {
                        Text("Turn on every category on the next screen so the full history can be exported. Nothing leaves your phone except to the server you set below.")
                    }
                }

                Section {
                    if let c = engine.credential {
                        LabeledContent("Server", value: c.base.host() ?? c.base.absoluteString)
                        LabeledContent("Signed in as", value: c.name)
                        Button("Sync now") {
                            Task { await engine.syncNow(trigger: .manual, deadline: nil) }
                        }
                        .disabled(!engine.authorized || engine.isRunning)
                        Button("Test connection") { Task { await testConnection() } }
                        if let connectionCheck {
                            Text(connectionCheck).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let server = engine.server, server.isPlainRemote {
                            Text("This address is plain http outside your own network: this iPhone's password would travel unencrypted. Use an https address.")
                                .font(.footnote).foregroundStyle(.red)
                        }
                        Button("Sign Out", role: .destructive) { Task { await engine.signOut() } }
                            .disabled(engine.isRunning)
                    } else {
                        Button("Sign In…") { engine.showSignIn = true }
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text(engine.credential == nil
                         ? "Sign in to your ioSuite server with your account's name and password. This iPhone gets a password of its own; the account must be an editor in ioHealth."
                         : "Remove this iPhone's password in Settings › Account on the server to stop it syncing.")
                }

                Section {
                    Toggle("Sync automatically", isOn: $engine.autoSync)
                        .onChange(of: engine.autoSync) { _, on in
                            if on { BackgroundSync.start(store: engine.reader.store) } else { BackgroundSync.stop(store: engine.reader.store) }
                        }
                    if let server = engine.server {
                        LabeledContent("Syncs to", value: server.baseURL.host() ?? server.baseURL.absoluteString)
                    }
                    if let date = engine.lastSynced {
                        LabeledContent("Last synced") {
                            VStack(alignment: .trailing) {
                                Text(date, format: .dateTime.day().month().hour().minute())
                                if let t = engine.lastTrigger { Text(label(for: t)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                } footer: {
                    Text("When on, the app syncs as soon as you open it, and iOS also wakes it in the background when new Health data arrives (roughly hourly, only while the phone is unlocked). If the server can't be reached, nothing is lost and the next sync catches up.")
                }

                Section {
                    NavigationLink {
                        DataTypesView(store: engine.reader.store) {
                            enabledTypes = TypeSelection.allIDs.filter(TypeSelection.isEnabled).count
                            if engine.autoSync { BackgroundSync.restart(store: engine.reader.store) }
                        }
                    } label: {
                        LabeledContent("Data types", value: "\(enabledTypes) of \(TypeSelection.allIDs.count) on")
                    }
                } footer: {
                    Text("Pick what gets synced. Switching a type off stops sending it; what was already sent stays on the server.")
                }

                Section {
                    Toggle("Send everything again", isOn: $engine.fullResync)
                } footer: {
                    Text("Normally only new or changed data is sent. Turn this on for a new or emptied database on the server.")
                }

            }
            .navigationTitle("ioHealthSync")
        }
        .sheet(isPresented: $engine.showSignIn) {
            NavigationStack {
                DeviceSignInForm(app: .iohealth, onSignedIn: { answer in
                    engine.signedIn(answer.credential)
                    autoSyncOnOpen()
                }, onCancel: { engine.showSignIn = false })
                .navigationTitle("Sign In")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { autoSyncOnOpen() }
        }
        .task { autoSyncOnOpen() }
    }

    private func autoSyncOnOpen() {
        guard engine.autoSync, engine.authorized, engine.hasTarget, !engine.isRunning else { return }
        if let last = engine.lastSynced, Date().timeIntervalSince(last) < 5 * 60 { return }
        Task { await engine.syncNow(trigger: .launch, deadline: nil) }
    }

    private func testConnection() async {
        guard let server = engine.server else { return }
        connectionCheck = "Checking…"
        do {
            let version = try await SyncClient.check(server)
            connectionCheck = "Reached the server and signed in (schema version \(version))."
        } catch SyncError.unauthorized {
            connectionCheck = nil
            engine.lostSignIn()
        } catch {
            connectionCheck = "Couldn't reach \(server.baseURL.absoluteString): \(error.localizedDescription)"
        }
    }

    private func label(for t: SyncEngine.Trigger) -> String {
        switch t {
        case .manual: return "started by you"
        case .launch: return "on opening the app"
        case .healthKit: return "in the background (new Health data)"
        case .backgroundRefresh: return "in the background (refresh)"
        }
    }

    @ViewBuilder private var status: some View {
        switch engine.state {
        case .idle: Text("Ready").foregroundStyle(.secondary)
        case .authorizing: Text("Waiting for Health permission…")
        case .syncing:
            VStack(alignment: .leading) {
                HStack { ProgressView(); Text("Reading \(engine.currentType)…") }
                Text("\(engine.sentCount.formatted()) items sent").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
        case .done(let n):
            Label("Done. \(n.formatted()) items sent.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .paused(let n):
            Label("Sent \(n.formatted()) items before iOS ended the background window; the rest goes next time.", systemImage: "pause.circle.fill")
                .foregroundStyle(.orange)
        case .failed(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
