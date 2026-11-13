import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false
    @State private var clearing = false
    @State private var cleared = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
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
                if let account = model.account {
                    Section {
                        LabeledContent("Start page", value: account.server.replacingOccurrences(of: "https://", with: ""))
                        LabeledContent("Signed in as", value: account.user)
                        if !model.canWrite { LabeledContent("Access", value: "Read only") }
                        Button("Sign out", role: .destructive) { asking = true }
                    } header: {
                        Text("Account")
                    } footer: {
                        Text("This phone signs in with a password of its own, for bookmarks only. To revoke it, open the start page's Settings › Account › App passwords.")
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
