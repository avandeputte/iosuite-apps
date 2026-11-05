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
            TVLibrary(signedOut: { step = .signIn }, switchProfile: { step = .signIn })
                .preferredColorScheme(.dark)  // the pages sit on a dark photo whatever the TV's appearance setting
        }
    }

    private func check() async {
        do {
            let a = try await IopixClient.shared.account()
            // more than one person has used this TV: ask who is watching (no password for someone signed in before)
            let ask = TVPrefs.shared.askWhoIsWatching && Profiles.names.count > 1
            step = a.signedIn && !ask ? .library : .signIn
        } catch IopixError.needsSignIn {
            step = .signIn
        } catch {
            step = .signIn  // shows the problem there, with a way to change the server
        }
    }
}

struct TVServerSetup: View {
    let done: (URL) -> Void
    @State private var text = AppConfig.hasServer ? AppConfig.serverURL.absoluteString : ""
    @State private var checking = false
    @State private var problem: String?
    @State private var tokenID = ServiceToken.clientID ?? ""
    @State private var tokenSecret = ServiceToken.clientSecret ?? ""
    @State private var showToken = ServiceToken.isSet

    var body: some View {
        VStack(spacing: 40) {
            Image("Mark").resizable().frame(width: 180, height: 180).clipShape(RoundedRectangle(cornerRadius: 40))
            Brand.text("Connect to your ").font(.title2.bold())
            Text("Enter the address of your iopix server, as you use it at home.").foregroundStyle(.secondary)
            TextField("photos.example.com", text: $text)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(width: 900)
                .onSubmit(connect)
            if showToken {
                VStack(spacing: 20) {
                    TextField("Cloudflare Access client ID", text: $tokenID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Cloudflare Access client secret", text: $tokenSecret)
                    Text("With a service token the Apple TV gets through Cloudflare Access to iopix's own sign-in. Leave it empty if iopix isn't behind Cloudflare.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(width: 900)
            }
            if let problem { Text(problem).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 1200) }
            HStack(spacing: 40) {
                Button(checking ? "Checking…" : "Connect", action: connect)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                if !showToken {
                    Button("Cloudflare Access service token…") { showToken = true }
                }
            }
        }
    }

    private func connect() {
        guard let url = AppConfig.normalisedServer(text) else { problem = "That doesn't look like a web address."; return }
        // kept before the check, which sends it along (the Keychain drops an empty one)
        ServiceToken.clientID = tokenID.trimmingCharacters(in: .whitespacesAndNewlines)
        ServiceToken.clientSecret = tokenSecret.trimmingCharacters(in: .whitespacesAndNewlines)
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
    @FocusState private var focus: String?

    var body: some View {
        VStack(spacing: 40) {
            VStack(spacing: 10) { Brand.name().font(.system(size: 76, weight: .bold)); Text("Who's watching?").font(.title2.bold()) }
            if accounts.isEmpty && problem == nil { ProgressView() }
            HStack(spacing: 40) {
                ForEach(accounts, id: \.name) { a in
                    Button {
                        chosen = a.name
                        password = ""
                        Task {
                            if await resume(a.name) { done() } else if !a.needsPassword { signIn() }
                        }
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill").font(.system(size: 90))
                            Text(a.name)
                            if Profiles.names.contains(a.name) { Text("no password needed").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .frame(width: 240, height: 220)
                    }
                    .buttonStyle(.card)
                    .focused($focus, equals: a.name)
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
            // the people who have used this TV first, the last one first: they need no password
            let known = Profiles.names
            let order = accounts.enumerated().map { ($0.offset, $0.element) }
            accounts = order.sorted { a, b in  // known ones first, the rest in the server's order (a stable sort)
                let ka = known.firstIndex(of: a.1.name) ?? Int.max, kb = known.firstIndex(of: b.1.name) ?? Int.max
                return ka != kb ? ka < kb : a.0 < b.0
            }.map(\.1)
            try? await Task.sleep(nanoseconds: 100_000_000)
            focus = accounts.first?.name
            if accounts.isEmpty { problem = "This iopix has no accounts to sign in with." }
        } catch IopixError.needsSignIn {
            // Cloudflare Access's sign-in page in front of iopix: the TV has no browser to show it
            problem = ServiceToken.isSet ? ServiceToken.rejected
                : "From here, iopix sits behind a sign-in page the Apple TV can't show. Add a Cloudflare Access service token (Change server), or use the server's address on your home network."
        } catch {
            problem = "iopix can't be reached: \(error.localizedDescription)"
        }
    }

    /// Someone who signed in on this TV before: their session is put back.
    private func resume(_ name: String) async -> Bool {
        guard Profiles.names.contains(name), Profiles.use(name) else { return false }
        if let a = try? await IopixClient.shared.account(), a.signedIn, a.name?.lowercased() == name.lowercased() { return true }
        Profiles.forget(name)  // the session ran out: a password is needed again
        return false
    }

    private func signIn() {
        guard let chosen else { return }
        busy = true
        problem = nil
        Task {
            do {
                try await IopixClient.shared.signIn(name: chosen, password: password)
                Profiles.save(chosen)
                done()
            } catch {
                problem = error.localizedDescription
            }
            busy = false
        }
    }
}
