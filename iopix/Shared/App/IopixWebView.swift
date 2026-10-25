import SwiftUI
import WebKit
import Network

/// The web view's cookies are the sign-in: iopix's session and, from outside, Cloudflare Access's. They are
/// copied to the store the uploads (and the iPhone share extension) use, whenever they change.
enum CookieSync {
    @MainActor
    static func pull(from store: WKHTTPCookieStore) async {
        #if os(iOS)
        // without an App Group the uploads use the store the web view already shares: copying would only loop
        guard AppConfig.hasGroup else { return }
        #endif
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

    /// The other way: a sign-in made in the app goes to the web page's store, so the page is signed in too (and
    /// `pull` does not take it for a sign-out on the page).
    @MainActor
    static func push() async {
        let host = AppConfig.serverURL.host?.lowercased() ?? ""
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in AppConfig.cookies.cookies ?? [] where matches(c, host) {
            await store.setCookie(c)
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

    private func make(_ context: Context) -> WKWebView { Self.build(context.coordinator, url: url) }

    /// The web view with everything the app adds to it. On iPhone and iPad it is made once and moved between the
    /// tabs that show the web app (WebShell); on the Mac it belongs to its window.
    static func build(_ coordinator: Coordinator, url: URL) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        #if os(iOS)
        cfg.allowsInlineMediaPlayback = true
        #endif
        #if os(macOS)
        // right-clicking a photo: the page says which one, and the native menu gets Add to / Remove from Favorites
        cfg.userContentController.addUserScript(WKUserScript(source: PhotoMenu.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController.add(PhotoMenu.Relay(coordinator), name: PhotoMenu.handler)
        let web = PhotoMenuWebView(frame: .zero, configuration: cfg)
        web.photoMenu = coordinator.photoMenu
        #else
        // inside the app's own tabs: the page's own bar and side menu give way to them, and the app hears where the
        // page is (so a link to Explore opens the native Explore)
        cfg.userContentController.addUserScript(WKUserScript(source: WebShell.pageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController.add(WebShell.Relay(), name: WebShell.handler)
        let web = WKWebView(frame: .zero, configuration: cfg)
        #endif
        web.navigationDelegate = coordinator
        web.uiDelegate = coordinator
        web.allowsBackForwardNavigationGestures = true
        #if os(iOS)
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        #else
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        #endif
        #if os(iOS)
        let refresh = UIRefreshControl()
        refresh.addTarget(coordinator, action: #selector(Coordinator.reload(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        web.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        cfg.websiteDataStore.httpCookieStore.add(coordinator)
        coordinator.web = web
        coordinator.status?.web = web
        coordinator.watchNetwork()
        let st = coordinator.status
        coordinator.reloadObserver = NotificationCenter.default.addObserver(forName: Notification.Name.iopixReload, object: nil, queue: .main) { [weak web, weak st] _ in
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
        private var lastPath: (interfaces: Set<NWInterface.InterfaceType>, gateways: Set<String>)?
        private var pendingReload: Task<Void, Never>?

        init(_ changed: @escaping () -> Void, status: WebStatus?) { self.changed = changed; self.status = status }

        #if os(macOS)
        let photoMenu = PhotoMenu()
        #endif

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
            // the route matters (which gateway, Wi-Fi or cellular in use), not every interface that comes and goes
            let kinds: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .other]
            let used = kinds.filter { path.usesInterfaceType($0) }
            let now = (interfaces: Set(used), gateways: Set(path.gateways.map { "\($0)" }))
            defer { lastPath = now }
            guard path.status == .satisfied, let web else { return }
            let moved = lastPath.map { $0 != now } ?? false
            guard status?.failed != nil || moved else { return }
            pendingReload?.cancel()
            pendingReload = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)  // let the new network settle
                guard !Task.isCancelled else { return }
                #if os(iOS)
                guard UIApplication.shared.applicationState == .active else { return }  // once the app is in front, it retries
                #endif
                self.status?.failed = nil
                web.reload()
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
            if e.domain == "WebKitErrorDomain" && e.code == 102 { return }  // "frame load interrupted": a download or a link handed to another app, not a failure
            // a link to some other site that failed is not iopix failing; only iopix's own address counts
            if let failing = e.userInfo[NSURLErrorFailingURLErrorKey] as? URL, let host = failing.host?.lowercased(),
               host != AppConfig.serverURL.host?.lowercased(), web?.url != nil { return }
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

#if os(macOS)
/// Favorites from the right-click menu. The page reports which photo the pointer is on (from its picture's
/// address: thumb/, preview/ or orig/ followed by the photo's number) just before WebKit opens its menu, and
/// the menu gets Add to Favorites or Remove from Favorites for it. The server does the change, as the page would.
@MainActor
final class PhotoMenu: NSObject {
    static let handler = "iopixPhotoMenu"
    static let script = """
    document.addEventListener('contextmenu', function (e) {
      // the picture itself, or the grid tile or viewer frame it sits in (never a whole page that has pictures)
      var t = e.target, box = t.closest ? t.closest('.tile, .lb-frame') : null;
      var img = t.tagName === 'IMG' ? t : (box ? box.querySelector('img') : null);
      var src = img ? (img.currentSrc || img.src || '') : '';
      var m = src.match(/\\/(?:thumb|preview|orig)\\/(\\d+)/);
      try { window.webkit.messageHandlers.\(handler).postMessage(m ? Number(m[1]) : 0); } catch (_) {}
    }, true);
    """

    private var photo: Int?
    private var at = Date.distantPast
    private var favorites: Set<Int> = []
    private var known = false  // favorites read from the server at least once

    /// The page's message: the photo under the pointer (0: none).
    func pointed(at id: Int) {
        photo = id > 0 ? id : nil
        at = Date()
        Task { await refresh() }  // for the next menu: a change made in the page meanwhile is picked up
    }

    func refresh() async {
        guard let st = try? await IopixClient.shared.json("api/state") else { return }
        favorites = Set((st["favorites"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue })
        known = true
    }

    /// Adds the item to WebKit's menu when the right-click was on a photo.
    func extend(_ menu: NSMenu) {
        let item: NSMenuItem
        if let id = photo, Date().timeIntervalSince(at) < 2 {
            let on = !favorites.contains(id)
            item = NSMenuItem(title: on ? "Add to Favorites" : "Remove from Favorites", action: #selector(toggle(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: on ? "heart" : "heart.slash", accessibilityDescription: nil)
            item.representedObject = [id, on ? 1 : 0]
        } else if menu.items.contains(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenImageInNewWindow" }) {
            // a picture, but the page's note has not come yet: which one is settled when the item is picked
            item = NSMenuItem(title: "Favorite / Unfavorite", action: #selector(toggle(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "heart", accessibilityDescription: nil)
        } else {
            return
        }
        item.target = self
        if !known { Task { await refresh() } }
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        let id: Int, on: Bool
        if let v = sender.representedObject as? [Int], v.count == 2 {
            id = v[0]; on = v[1] == 1
        } else if let p = photo, Date().timeIntervalSince(at) < 30 {
            id = p; on = !favorites.contains(p)
        } else {
            return
        }
        photo = nil
        Task {
            var r = IopixClient.shared.request("api/favorites", method: "POST")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": [id], "on": on])
            do {
                let (data, resp) = try await IopixClient.shared.session.data(for: r)
                _ = try IopixClient.shared.check(data, resp)
                if on { favorites.insert(id) } else { favorites.remove(id) }
                web?.evaluateJavaScript(Self.toast(on ? "Added to favorites." : "Removed from favorites."), completionHandler: nil)
            } catch {
                NSSound.beep()
                web?.evaluateJavaScript(Self.toast("Could not save the favorite."), completionHandler: nil)
            }
        }
    }

    weak var web: WKWebView?

    /// A short note at the bottom of the page, like the page's own.
    private static func toast(_ text: String) -> String {
        """
        (function () { var d = document.createElement('div'); d.textContent = \(String(reflecting: text));
          d.style.cssText = 'position:fixed;left:50%;bottom:28px;transform:translateX(-50%);background:rgba(30,30,30,.92);color:#fff;padding:10px 18px;border-radius:20px;font:14px -apple-system,system-ui;z-index:99999;transition:opacity .4s';
          document.body.appendChild(d); setTimeout(function () { d.style.opacity = '0'; setTimeout(function () { d.remove(); }, 450); }, 1800); })();
        """
    }

    /// Kept apart from the coordinator: the page's message handler would otherwise keep it alive for good.
    final class Relay: NSObject, WKScriptMessageHandler {
        weak var coordinator: IopixWebView.Coordinator?
        init(_ c: IopixWebView.Coordinator) { coordinator = c }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let id = (message.body as? NSNumber)?.intValue ?? 0
            MainActor.assumeIsolated { coordinator?.photoMenu.pointed(at: id) }
        }
    }
}

final class PhotoMenuWebView: WKWebView {
    weak var photoMenu: PhotoMenu? { didSet { photoMenu?.web = self } }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        MainActor.assumeIsolated { photoMenu?.extend(menu) }
    }
}
#endif
