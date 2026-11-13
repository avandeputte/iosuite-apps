import SwiftUI
import AuthenticationServices

/// The start page's address, then its own "let this app sync?" page in a sign-in sheet: no password is typed here.
struct SignInView: View {
    @EnvironmentObject private var model: AppModel
    @State private var address = Shared.defaults.string(forKey: "lastServer") ?? ""
    @State private var working = false
    @State private var failure: String?
    @StateObject private var sheet = SignInSheet()
    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image("Mark")
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.top, 48)
                Text("ioStart").font(.largeTitle.bold())
                Text("Your ioSuite start page's bookmarks, on this phone.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Start page address").font(.footnote).foregroundStyle(.secondary)
                    TextField("start.example.com", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($typing)
                        .onSubmit { Task { await signIn() } }
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.top, 12)

                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        if working { ProgressView().tint(.white) }
                        Text(working ? "Waiting for your yes…" : "Sign in")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || address.trimmingCharacters(in: .whitespaces).isEmpty)

                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Text("A page of your start page opens. Sign in there if asked, then tap Allow. This phone gets a password of its own, for bookmarks only, that you can revoke in the start page's Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func signIn() async {
        guard !working else { return }
        typing = false
        failure = nil
        working = true
        defer { working = false }
        let server = API.root(address)
        do {
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
            let flow = try await API.startFlow(server: server, client: "ioStart on \(device)")
            guard let page = flow.page(on: server) else { throw APIError.unreachable("The start page's answer could not be read.") }
            Shared.defaults.set(address, forKey: "lastServer")
            guard let got = await sheet.run(page: page, server: server, token: flow.poll.token) else { return }  // closed without a yes
            await model.signedIn(Account(server: server, user: got.loginName, password: got.appPassword))
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Shows the start page's allow page in the system's sign-in sheet (it shares Safari's sign-ins, and proxies such as
/// Cloudflare Access accept it, which they do not for a web view inside an app) and asks the start page every two
/// seconds whether somebody said yes; then the sheet closes by itself.
@MainActor
final class SignInSheet: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var closed = false

    func run(page: URL, server: String, token: String) async -> API.Granted? {
        closed = false
        let session = ASWebAuthenticationSession(url: page, callbackURLScheme: "iostart") { [weak self] _, _ in
            Task { @MainActor in self?.closed = true }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        guard session.start() else { return nil }
        defer {
            session.cancel()
            self.session = nil
        }
        let until = Date().addingTimeInterval(20 * 60)  // as long as the start page keeps the request
        while Date() < until {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let got = try? await API.pollFlow(server: server, token: token) { return got }
            if closed {  // closed by hand: one more look, for a yes given just before
                return try? await API.pollFlow(server: server, token: token)
            }
        }
        return nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
