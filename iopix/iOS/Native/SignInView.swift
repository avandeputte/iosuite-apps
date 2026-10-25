import SwiftUI
import WebKit

/// Signing in to iopix from the app itself: pick an account, give its password. The sign-in is kept for the
/// uploads, the share sheet and the web page ("Open in iopix") alike.
struct SignInView: View {
    var changeServer: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var store: LibraryStore
    @State private var accounts: [(name: String, needsPassword: Bool)] = []
    @State private var loading = true
    @State private var chosen: String?
    @State private var password = ""
    @State private var problem: String?
    @State private var busy = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if loading {
                        ProgressView()
                    } else if accounts.isEmpty {
                        Text(problem ?? "This iopix has no accounts to sign in with.").foregroundStyle(.secondary)
                    }
                    ForEach(accounts, id: \.name) { a in
                        Button {
                            chosen = a.name
                            password = ""
                            problem = nil
                            if a.needsPassword { passwordFocused = true } else { signIn() }
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
                                Text(a.name).foregroundStyle(.primary)
                                Spacer()
                                if chosen == a.name { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                    }
                } header: {
                    Text("Who are you?")
                } footer: {
                    Text(AppConfig.serverURL.host ?? "")
                }
                if let chosen, accounts.first(where: { $0.name == chosen })?.needsPassword == true {
                    Section {
                        SecureField("Password for \(chosen)", text: $password)
                            .textContentType(.password)
                            .focused($passwordFocused)
                            .onSubmit(signIn)
                        Button(busy ? "Signing in…" : "Sign in", action: signIn).disabled(password.isEmpty || busy)
                    }
                }
                if let problem, !accounts.isEmpty {
                    Section { Text(problem).foregroundStyle(.red) }
                }
                Section {
                    Button("Change server…") { dismiss(); changeServer() }
                }
            }
            .navigationTitle("Sign in to iopix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await loadAccounts() }
        }
    }

    private func loadAccounts() async {
        do {
            accounts = try await IopixClient.shared.accounts()
            if accounts.count == 1, let only = accounts.first { chosen = only.name; if only.needsPassword { passwordFocused = true } }
        } catch {
            problem = "iopix can't be reached: \(error.localizedDescription)"
        }
        loading = false
    }

    private func signIn() {
        guard let chosen, !busy else { return }
        busy = true
        problem = nil
        Task {
            do {
                try await IopixClient.shared.signIn(name: chosen, password: password)
                await CookieSync.push()  // the web page ("Open in iopix") signs in with it too
                await queue.refreshAccount()
                await store.load()
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            busy = false
        }
    }
}
