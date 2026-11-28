import SwiftUI

@main
struct RecipeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onChange(of: phase) { _, now in
                    if now == .active { Task { await model.refresh() } }  // also shows what the share sheet imported
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.credential == nil {
                SignInView()
            } else {
                LibraryView()
            }
        }
        .sheet(isPresented: $model.showSettings) { SettingsView().environmentObject(model) }
        .alert("Something went wrong", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }
}

/// The sign-in of the ioSuite apps (shared/DeviceSignIn): the server's address for apps, the name and password,
/// and the code of two-step sign-in when the account has it. This device gets an app password of its own.
struct SignInView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            DeviceSignInForm(app: .iorecipe) { answer in
                Task { await model.signedIn(answer.credential) }
            }
            .safeAreaInset(edge: .top) {
                HStack(spacing: 12) {
                    Image("Mark")
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading) {
                        Text("ioRecipe").font(.title2.bold())
                        Text("The family's recipes, to cook from.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Keep the screen on", isOn: $model.keepAwake)
                } footer: {
                    Text("While a recipe is open, the screen does not dim or lock by itself.")
                }
                Section {
                    Label("In your browser, tap Share, then ioRecipe: the recipe on the page is imported. The first time, tap More at the end of the row of apps and turn it on.", systemImage: "square.and.arrow.up")
                        .font(.callout)
                } header: {
                    Text("Import a recipe from your browser")
                }
                if let c = model.credential {
                    Section {
                        LabeledContent("Server", value: c.address.replacingOccurrences(of: "https://", with: ""))
                        LabeledContent("Signed in as", value: model.me?.user?.displayName ?? c.name)
                        if !model.mayAdd { LabeledContent("Access", value: "Read only") }
                        Button("Sign out", role: .destructive) { asking = true }
                    } header: {
                        Text("Account")
                    } footer: {
                        Text("This device signs in with a password of its own. Signing out gives it back; you can also remove it in Settings › Account on the web.")
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
            .confirmationDialog("Sign out of ioRecipe?", isPresented: $asking, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    dismiss()
                    model.signOut()
                }
            }
        }
    }
}
