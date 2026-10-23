import SwiftUI
import WebKit

/// The web view's cookies are the sign-in: iopix's session and, from outside, Cloudflare Access's. They are
/// copied to the store the uploads (and the iPhone share extension) use, whenever they change.
enum CookieSync {
    @MainActor
    static func pull(from store: WKHTTPCookieStore) async {
        let host = AppConfig.serverURL.host?.lowercased() ?? ""
        let web = await store.allCookies().filter { matches($0, host) }
        let names = Set(web.map { "\($0.domain)|\($0.name)" })
        for c in AppConfig.cookies.cookies ?? [] where matches(c, host) && !names.contains("\(c.domain)|\(c.name)") {
            AppConfig.cookies.deleteCookie(c)  // signed out on the page
        }
        for c in web {
            var props = c.properties ?? [:]
            if c.expiresDate == nil {  // keep a browser-session cookie across launches; the token in it still expires on time
                props[.expires] = Date().addingTimeInterval(7 * 86400)
                props.removeValue(forKey: .discard)
            }
            if let copy = HTTPCookie(properties: props) { AppConfig.cookies.setCookie(copy) }
        }
    }

    static func matches(_ c: HTTPCookie, _ host: String) -> Bool {
        let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == d || host.hasSuffix("." + d)
    }

    @MainActor
    static func clearWebView() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
    }
}

#if os(iOS)
typealias PlatformViewRepresentable = UIViewRepresentable
#else
typealias PlatformViewRepresentable = NSViewRepresentable
#endif

/// iopix's own web app, signed in with the same cookies as a browser.
struct IopixWebView: PlatformViewRepresentable {
    let url: URL
    var onCookiesChanged: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onCookiesChanged) }

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { make(context) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    #else
    func makeNSView(context: Context) -> WKWebView { make(context) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    #endif

    private func make(_ context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        #if os(iOS)
        cfg.allowsInlineMediaPlayback = true
        #endif
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        #if os(iOS)
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.reload(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        web.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        cfg.websiteDataStore.httpCookieStore.add(context.coordinator)
        context.coordinator.web = web
        web.load(URLRequest(url: url))
        return web
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        let changed: () -> Void
        weak var web: WKWebView?
        private var pending: Task<Void, Never>?

        init(_ changed: @escaping () -> Void) { self.changed = changed }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            pending?.cancel()
            pending = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await CookieSync.pull(from: cookieStore)
                changed()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            #if os(iOS)
            webView.scrollView.refreshControl?.endRefreshing()
            #endif
            cookiesDidChange(in: webView.configuration.websiteDataStore.httpCookieStore)
        }

        /// Links that open a new window: iopix's own pages stay here, anything else opens in the browser.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            if url.host == AppConfig.serverURL.host {
                webView.load(navigationAction.request)
            } else {
                #if os(iOS)
                UIApplication.shared.open(url)
                #else
                NSWorkspace.shared.open(url)
                #endif
            }
            return nil
        }

        #if os(iOS)
        @objc func reload(_ sender: UIRefreshControl) { web?.reload() }
        #endif
    }
}
