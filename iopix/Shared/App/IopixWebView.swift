import SwiftUI
import WebKit
import Network

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
/// How the page is doing, for the native shell: a failed load shows a message and a Retry button, and the page
/// is loaded again by itself when the network comes back or changes (home Wi-Fi to cellular, for example).
@MainActor
final class WebStatus: ObservableObject {
    @Published var failed: String?   // why the last load failed, in plain words; nil while the page is fine
    @Published var loading = false
    fileprivate weak var web: WKWebView?

    func retry() {
        failed = nil
        guard let web else { return }
        if web.url == nil || web.url?.absoluteString == "about:blank" { web.load(URLRequest(url: AppConfig.serverURL)) } else { web.reload() }
    }
}

struct IopixWebView: PlatformViewRepresentable {
    let url: URL
    var status: WebStatus? = nil
    var onCookiesChanged: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onCookiesChanged, status: status) }

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
        context.coordinator.status?.web = web
        context.coordinator.watchNetwork()
        let st = context.coordinator.status
        context.coordinator.reloadObserver = NotificationCenter.default.addObserver(forName: Notification.Name.iopixReload, object: nil, queue: .main) { [weak web, weak st] _ in
            guard let web else { return }
            if let st { st.retry() }  // clears a failure first, and loads the server when the page never came
            else if web.url == nil { web.load(URLRequest(url: AppConfig.serverURL)) } else { web.reload() }
        }
        #if os(iOS)
        // the page's own drop handling is turned off, so a photo dragged onto the app (iPad, side by side) reaches
        // the app's drop target and goes to the queue instead of being swallowed or uploaded by the page itself
        for sub in web.scrollView.subviews {
            for interaction in sub.interactions where interaction is UIDropInteraction { sub.removeInteraction(interaction) }
        }
        #endif
        web.load(URLRequest(url: url))
        return web
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        let changed: () -> Void
        let status: WebStatus?
        weak var web: WKWebView?
        private var pending: Task<Void, Never>?
        private var monitor: NWPathMonitor?
        private var lastPath: (interfaces: [NWInterface.InterfaceType], gateways: [String])?

        init(_ changed: @escaping () -> Void, status: WebStatus?) { self.changed = changed; self.status = status }

        deinit {
            monitor?.cancel()
            if let reloadObserver { NotificationCenter.default.removeObserver(reloadObserver) }
        }

        /// A page that failed to load is tried again when the network is back; a page that loaded over one network
        /// (home Wi-Fi) is loaded again when the device moves to another (cellular, another Wi-Fi), because the
        /// connections it was using are gone and the server may now be reached by another route (Cloudflare).
        func watchNetwork() {
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in self?.pathChanged(path) }
            }
            m.start(queue: DispatchQueue(label: "iopix.network"))
            monitor = m
        }

        @MainActor private func pathChanged(_ path: NWPath) {
            let now = (interfaces: path.availableInterfaces.map(\.type), gateways: path.gateways.map { "\($0)" })
            defer { lastPath = now }
            guard path.status == .satisfied, let web else { return }
            let moved = lastPath.map { $0.interfaces != now.interfaces || $0.gateways != now.gateways } ?? false
            if status?.failed != nil || moved {
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)  // let the new network settle
                    guard self.status?.failed != nil || moved else { return }
                    self.status?.failed = nil
                    web.reload()
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            status?.loading = true
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }

        private func failed(_ error: Error) {
            status?.loading = false
            let e = error as NSError
            if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }  // a new load replaced this one
            let why: String
            switch (e.domain, e.code) {
            case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet): why = "You're offline."
            case (NSURLErrorDomain, NSURLErrorTimedOut): why = "iopix took too long to answer."
            case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed): why = "The server's address can't be found on this network."
            case (NSURLErrorDomain, NSURLErrorCannotConnectToHost), (NSURLErrorDomain, NSURLErrorNetworkConnectionLost): why = "iopix can't be reached from this network."
            default: why = e.localizedDescription
            }
            status?.failed = why
        }

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
            status?.loading = false
            status?.failed = nil
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

        var reloadObserver: NSObjectProtocol?

        #if os(iOS)
        @objc func reload(_ sender: UIRefreshControl) { web?.reload() }
        #else

        /// The page's own "choose files" buttons (uploads inside the web app).
        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
        }

        /// Exports and downloads from the page land in Downloads.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let attachment = ((navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment")
            decisionHandler(attachment || !navigationResponse.canShowMIMEType ? .download : .allow)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
        #endif
    }
}

#if os(macOS)
extension IopixWebView.Coordinator: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dst = folder.appendingPathComponent(suggestedFilename)
        let base = dst.deletingPathExtension().lastPathComponent, ext = dst.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        completionHandler(dst)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = download.progress.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
#endif
