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
    /// Away from home, the server can sit behind another sign-in first (Cloudflare Access): its page.
    @State private var gate: URL?
    @State private var showGate = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if gate != nil {
                    Section {
                        Button("Sign in to \(gate?.host ?? "the sign-in page")…") { showGate = true }
                    } header: {
                        Text("First, this network's sign-in")
                    } footer: {
                        if ServiceToken.isSet, ServiceToken.isCloudflareSignIn(gate) {
                            Text(ServiceToken.rejected + " Until then, sign in on Cloudflare's page.")
                        } else {
                            Text("From here, ioPix sits behind a sign-in page (your reverse proxy's, for example). Sign in there first, then to ioPix.")
                        }
                    }
                }
                Section {
                    if loading {
                        ProgressView()
                    } else if accounts.isEmpty, gate == nil {
                        Text(problem ?? "This ioPix has no accounts to sign in with.").foregroundStyle(.secondary)
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
            .navigationTitle("Sign in to ioPix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Cancel") } } }
            .task { await loadAccounts() }
            .sheet(isPresented: $showGate) {
                if let gate {
                    GateSignIn(start: gate) {
                        showGate = false
                        Task { await loadAccounts() }
                    }
                }
            }
        }
    }

    private func loadAccounts() async {
        loading = true
        problem = nil
        if let g = await IopixClient.shared.gate() {
            gate = g
            accounts = []
            loading = false
            showGate = true
            return
        }
        gate = nil
        // through the gate with the iopix sign-in still good (made at home): nothing more to ask
        if let me = try? await IopixClient.shared.account(), me.signedIn {
            await finish()
            return
        }
        do {
            accounts = try await IopixClient.shared.accounts()
            if accounts.count == 1, let only = accounts.first { chosen = only.name; if only.needsPassword { passwordFocused = true } }
        } catch {
            problem = "ioPix can't be reached: \(error.localizedDescription)"
        }
        loading = false
    }

    private func finish() async {
        await CookieSync.push()  // the web page ("Open in iopix") signs in with it too
        await queue.refreshAccount()
        await store.load()
        dismiss()
    }

    private func signIn() {
        guard let chosen, !busy else { return }
        busy = true
        problem = nil
        Task {
            do {
                try await IopixClient.shared.signIn(name: chosen, password: password)
                await finish()
            } catch IopixError.needsSignIn {
                await loadAccounts()  // the network changed under the sign-in: Cloudflare's comes first now
            } catch {
                problem = error.localizedDescription
            }
            busy = false
        }
    }
}

/// The sign-in page in front of iopix (Cloudflare Access), in a web view. Once it hands over to iopix's own address,
/// its cookies go to the app and the sheet closes.
struct GateSignIn: View {
    let start: URL
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GatePage(start: start, done: done)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(start.host ?? "Sign in")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Cancel") } } }
        }
    }
}

private struct GatePage: UIViewRepresentable {
    let start: URL
    let done: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()  // the web page's store: "Open in iopix" is let through as well
        let web = WKWebView(frame: .zero, configuration: cfg)
        // Safari's own: some sign-in providers turn away pages that look embedded
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: AppConfig.serverURL))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let done: () -> Void
        private var finished = false
        init(done: @escaping () -> Void) { self.done = done }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished, webView.url?.host?.lowercased() == AppConfig.serverURL.host?.lowercased() else { return }
            finished = true
            Task { @MainActor in
                // only adds: an iopix sign-in made in the app stays even if the page never had it
                await CookieSync.pull(from: webView.configuration.websiteDataStore.httpCookieStore, keepingOthers: true)
                done()
            }
        }

        /// A sign-in provider's pop-up opens in the same page.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            webView.load(navigationAction.request)
            return nil
        }
    }
}
