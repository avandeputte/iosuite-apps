import SwiftUI
import WebKit

/// Signing in the way iopix's apps do: the server's own sign-in page in a web view, exactly as in the browser
/// (Cloudflare Access's sign-in first, when the server sits behind it). The page's cookies are the sign-in; they
/// are copied to the store the sync uses whenever they change.
enum CookieSync {
    @MainActor
    static func pull(from store: WKHTTPCookieStore) async {
        guard let host = ServerConfig.serverURL?.host?.lowercased() else { return }
        let web = await store.allCookies().filter { matches($0, host) }
        let names = Set(web.map { "\($0.domain)|\($0.name)" })
        for c in HTTPCookieStorage.shared.cookies ?? [] where matches(c, host) && !names.contains("\(c.domain)|\(c.name)") {
            HTTPCookieStorage.shared.deleteCookie(c)  // signed out on the page
        }
        for c in web {
            var props = c.properties ?? [:]
            if c.expiresDate == nil {  // keep a browser-session cookie across launches; the token in it still expires on time
                props[.expires] = Date().addingTimeInterval(7 * 86400)
                props.removeValue(forKey: .discard)
            }
            if let copy = HTTPCookie(properties: props) { HTTPCookieStorage.shared.setCookie(copy) }
        }
    }

    /// The other way: the app's sign-in goes to the page, so the page opens signed in (and `pull` doesn't take
    /// its absence there for a sign-out).
    @MainActor
    static func push() async {
        guard let host = ServerConfig.serverURL?.host?.lowercased() else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in HTTPCookieStorage.shared.cookies ?? [] where matches(c, host) {
            await store.setCookie(c)
        }
    }

    /// Signing out also signs the page out.
    @MainActor
    static func clearWebView() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
    }

    static func matches(_ c: HTTPCookie, _ host: String) -> Bool {
        let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == d || host.hasSuffix("." + d)
    }
}

#if os(iOS)
typealias PlatformViewRepresentable = UIViewRepresentable
#else
typealias PlatformViewRepresentable = NSViewRepresentable
#endif

/// The server's web app, signed in with the same cookies as a browser.
struct ServerWebView: PlatformViewRepresentable {
    let url: URL
    @Binding var failed: String?
    var onCookiesChanged: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { make(context) }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.parent = self }
    #else
    func makeNSView(context: Context) -> WKWebView { make(context) }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.parent = self }
    #endif

    private func make(_ context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        cfg.websiteDataStore.httpCookieStore.add(context.coordinator)
        context.coordinator.web = web
        Task { @MainActor in
            await CookieSync.push()
            web.load(URLRequest(url: url))
        }
        return web
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        var parent: ServerWebView
        weak var web: WKWebView?
        private var pending: Task<Void, Never>?

        init(_ parent: ServerWebView) { self.parent = parent }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            // a burst of changes during a sign-in becomes one copy and one account check
            pending?.cancel()
            pending = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await CookieSync.pull(from: cookieStore)
                self.parent.onCookiesChanged()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.failed = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

        private func failed(_ error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            parent.failed = error.localizedDescription
        }
    }
}

/// The sign-in window (Mac) or sheet (iPhone, iPad): the server's page above, and below it whether this device
/// is signed in yet, as in iopix.
struct SignInView: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    @State private var failed: String?
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            if let url = ServerConfig.serverURL {
                ZStack {
                    ServerWebView(url: url, failed: $failed) { Task { await store.refreshAccount() } }
                        .id(attempt)
                    if let failed {
                        VStack(spacing: 10) {
                            Text("Couldn't open \(url.host ?? "the server")").font(.headline)
                            Text(failed).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Retry") { self.failed = nil; attempt += 1 }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                    }
                }
            }
            Divider()
            HStack {
                if let a = store.account, a.canWrite {
                    Label("Signed in as \(a.name ?? "you"). Notes sync now.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                } else if let a = store.account, a.signedIn {
                    Text("\(a.name ?? "This account") can read notes but not change them. Sign in with another account.")
                    Spacer()
                    Button("Close") { dismiss() }
                } else {
                    Text("Sign in on the page above, the way you do in the browser.")
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(10)
            .font(.callout)
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 520, idealHeight: 640)
        #endif
    }
}
