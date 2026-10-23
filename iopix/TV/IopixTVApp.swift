import SwiftUI

@main
struct IopixTVApp: App {
    var body: some Scene {
        WindowGroup { TVRoot() }
    }
}

/// Server address, then sign-in, then the library.
struct TVRoot: View {
    enum Step { case checking, server, signIn, library }
    @State private var step: Step = AppConfig.hasServer ? .checking : .server

    var body: some View {
        switch step {
        case .checking:
            ProgressView().task { await check() }
        case .server:
            TVServerSetup { url in
                AppConfig.serverURL = url
                step = .checking
            }
        case .signIn:
            TVSignIn(changeServer: { step = .server }) { step = .library }
        case .library:
            TVLibrary { step = .signIn }
        }
    }

    private func check() async {
        do {
            let a = try await IopixClient.shared.account()
            step = a.signedIn ? .library : .signIn
        } catch IopixError.needsSignIn {
            step = .signIn
        } catch {
            step = .signIn  // shows the problem there, with a way to change the server
        }
    }
}

struct TVServerSetup: View {
    let done: (URL) -> Void
    @State private var text = ""
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 40) {
            Image("Mark").resizable().frame(width: 180, height: 180).clipShape(RoundedRectangle(cornerRadius: 40))
            Text("Connect to your iopix").font(.title2.bold())
            Text("Enter the address of your iopix server, as you use it at home.").foregroundStyle(.secondary)
            TextField("photos.example.com", text: $text)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(width: 900)
                .onSubmit(connect)
            if let problem { Text(problem).foregroundStyle(.red) }
            Button(checking ? "Checking…" : "Connect", action: connect)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || checking)
        }
    }

    private func connect() {
        guard let url = AppConfig.normalisedServer(text) else { problem = "That doesn't look like a web address."; return }
        checking = true
        problem = nil
        Task {
            problem = await IopixClient.shared.probe(url)
            checking = false
            if problem == nil { done(url) }
        }
    }
}

struct TVSignIn: View {
    let changeServer: () -> Void
    let done: () -> Void
    @State private var accounts: [(name: String, needsPassword: Bool)] = []
    @State private var chosen: String?
    @State private var password = ""
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 40) {
            Text("Who's watching?").font(.title2.bold())
            if accounts.isEmpty && problem == nil { ProgressView() }
            HStack(spacing: 40) {
                ForEach(accounts, id: \.name) { a in
                    Button {
                        chosen = a.name
                        password = ""
                        if !a.needsPassword { signIn() }
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill").font(.system(size: 90))
                            Text(a.name)
                        }
                        .frame(width: 240, height: 220)
                    }
                    .buttonStyle(.card)
                }
            }
            if let chosen, accounts.first(where: { $0.name == chosen })?.needsPassword == true {
                SecureField("Password for \(chosen)", text: $password)
                    .frame(width: 700)
                    .onSubmit(signIn)
                Button(busy ? "Signing in…" : "Sign in", action: signIn).disabled(password.isEmpty || busy)
            }
            if let problem { Text(problem).foregroundStyle(.red).multilineTextAlignment(.center) }
            Button("Change server (\(AppConfig.serverURL.host ?? ""))", action: changeServer).font(.callout)
        }
        .task { await loadAccounts() }
    }

    private func loadAccounts() async {
        do {
            accounts = try await IopixClient.shared.accounts()
            if accounts.isEmpty { problem = "This iopix has no accounts to sign in with." }
        } catch {
            problem = "iopix can't be reached: \(error.localizedDescription)"
        }
    }

    private func signIn() {
        guard let chosen else { return }
        busy = true
        problem = nil
        Task {
            do {
                try await IopixClient.shared.signIn(name: chosen, password: password)
                done()
            } catch {
                problem = error.localizedDescription
            }
            busy = false
        }
    }
}
