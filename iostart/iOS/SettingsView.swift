import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false
    @State private var clearing = false
    @State private var cleared = false
    @StateObject private var sheet = SignInSheet()
    @State private var renewing = false
    @State private var renewFailure: String?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// The sign-in flow again, on the same start page, for a full app password.
    private func signInAgain(_ account: Account) async {
        renewing = true
        renewFailure = nil
        defer { renewing = false }
        do {
            guard let fresh = try await sheet.signIn(server: account.server) else { return }
            await model.signedIn(fresh)
            if model.full == false { renewFailure = "The start page still gave a password for bookmarks only. Is it up to date?" }
        } catch {
            renewFailure = error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Open bookmarks", selection: $model.openIn) {
                        ForEach(OpenIn.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Search with", selection: $model.searchWith) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                    }
                } footer: {
                    Text("Either way, press and hold a bookmark to open it the other way, or in a private page. What you type in the browser's address bar that is not an address is searched for with the search engine above.")
                }
                Section {
                    Button(cleared ? "Browsing data cleared" : "Clear browsing data", role: .destructive) { clearing = true }
                        .disabled(cleared)
                } footer: {
                    Text("Forgets the sign-ins, cookies and caches of the pages opened here. Private pages never keep any.")
                }
                .confirmationDialog("Clear browsing data?", isPresented: $clearing, titleVisibility: .visible) {
                    Button("Clear browsing data", role: .destructive) {
                        Task {
                            await clearBrowsingData()
                            cleared = true
                        }
                    }
                } message: {
                    Text("Websites you are signed in to in ioStart will ask you to sign in again. Your bookmarks stay.")
                }
                Section {
                    Label("In your browser, tap Share, then ioStart. The first time, tap More at the end of the row of apps and turn it on.", systemImage: "square.and.arrow.up")
                        .font(.callout)
                } header: {
                    Text("Add a page from your browser")
                }
                if let account = model.account, model.full == false {
                    Section {
                        Button {
                            Task { await signInAgain(account) }
                        } label: {
                            HStack {
                                Text(renewing ? "Waiting for your yes…" : "Sign in again")
                                if renewing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(renewing)
                        if let renewFailure {
                            Text(renewFailure).font(.footnote).foregroundStyle(.red)
                        }
                    } header: {
                        Text("Widgets and Siri")
                    } footer: {
                        Text("This phone's password is for bookmarks only. Sign in again to turn on the widgets (your day, your tasks) and the Siri and Shortcuts actions (add a task, add an event, show today). Afterwards you can revoke the old password, “Bookmark sync: ioStart…”, in the start page's Settings › Account › App passwords.")
                    }
                }
                if let account = model.account {
                    Section {
                        LabeledContent("Start page", value: account.server.replacingOccurrences(of: "https://", with: ""))
                        LabeledContent("Signed in as", value: account.user)
                        if !model.canWrite { LabeledContent("Access", value: "Read only") }
                        Button("Sign out", role: .destructive) { asking = true }
                    } header: {
                        Text("Account")
                    } footer: {
                        Text("This phone signs in with a password of its own. To revoke it, open the start page's Settings › Account › App passwords.")
                    }
                }
                Section {
                    LabeledContent("Version", value: version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Sign out of this start page?", isPresented: $asking, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    dismiss()
                    model.signOut()
                }
            }
        }
    }
}
