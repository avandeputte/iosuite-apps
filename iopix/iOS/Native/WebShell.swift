import SwiftUI
import WebKit

/// The tabs at the bottom (a sidebar on iPad). Explore is native; the others show the web app at their page until
/// they get their own native screens.
enum AppTab: String, Hashable, CaseIterable {
    case explore, photos, people, places, more

    var title: String {
        switch self {
        case .explore: return "Explore"
        case .photos: return "Photos"
        case .people: return "People"
        case .places: return "Places"
        case .more: return "More"
        }
    }

    var symbol: String {
        switch self {
        case .explore: return "safari"
        case .photos: return "photo.on.rectangle"
        case .people: return "person.2"
        case .places: return "mappin.and.ellipse"
        case .more: return "ellipsis.circle"
        }
    }

    /// The web app's page a web tab opens on.
    var home: String {
        switch self {
        case .explore, .photos: return "#/photos"
        case .people: return "#/people"
        case .places: return "#/places"
        case .more: return "#/folders"
        }
    }
}

/// Which tab is showing, and the web page each web tab was last on.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()

    @Published var tab: AppTab = .explore
    /// Pages opened from More, one deep (a page of the web app each).
    @Published var morePath: [String] = []
    var lastRoute: [AppTab: String] = [:]

    /// Opens a page of the web app ("#/photos?year=2020") in the tab it belongs to.
    func open(_ route: String) {
        let view = route.dropFirst(2).split(whereSeparator: { $0 == "?" || $0 == "/" }).first.map(String.init) ?? "photos"
        let target: AppTab
        switch view {
        case "people", "faces": target = .people
        case "places": target = .places
        case "photos", "favorites": target = .photos
        default: target = .more
        }
        lastRoute[target] = route
        if target == .more {
            morePath = [route]
        }
        if tab == target, target != .more { WebShell.shared.go(route) }
        tab = target
    }
}

/// The one web view of the app. Every web tab shows it in turn: it moves into whichever tab is on screen and goes
/// to that tab's page, so the web app loads once and stays signed in.
@MainActor
final class WebShell {
    static let shared = WebShell()
    static let handler = "iopixRoute"

    let status = WebStatus()
    var onCookiesChanged: () -> Void = {}
    private var web: WKWebView?
    private var coordinator: IopixWebView.Coordinator?
    private var server: URL?
    /// Where the page is now ("#/people"), as it reports it.
    private(set) var hash = ""
    /// The tab the web view is in, and the route it was asked for there.
    private var owner: AppTab?

    /// Hides the page's own bottom bar and side menu (the app's tabs replace them), and tells the app where the
    /// page is whenever it changes.
    static let pageScript = """
    (function () {
      var css = '#nav,#sidebtn,#menubtn,#navscrim{display:none!important}' +
        'body.side-docked{--nav:0px!important}' +
        '#main,#filters,html.vpshort #main,html.vpshort #filters{bottom:0!important}' +
        '.cbulk,html.vpshort .cbulk{bottom:0!important}';
      var s = document.createElement('style'); s.textContent = css; document.head.appendChild(s);
      function tell() { try { window.webkit.messageHandlers.\(handler).postMessage(location.hash || ''); } catch (_) {} }
      window.addEventListener('hashchange', tell); tell();
    })();
    """

    /// The web view, made on first use (and again after the server address changed), opening on `start`.
    private func webView(start: String) -> WKWebView {
        if let web, server == AppConfig.serverURL { return web }
        web?.removeFromSuperview()
        let c = IopixWebView.Coordinator(onCookiesChanged, status: status)
        coordinator = c
        server = AppConfig.serverURL
        let w = IopixWebView.build(c, url: Self.url(for: start))
        web = w
        hash = start
        return w
    }

    /// Starts over with the current server address (it was changed in settings).
    func reset() {
        web?.removeFromSuperview()
        web = nil
        hash = ""
        status.failed = nil
    }

    /// Moves the web view into a tab's container and shows that tab's page.
    func adopt(into host: UIView, tab: AppTab, route: String) {
        let w = webView(start: route)
        if let previous = owner, previous != tab, !hash.isEmpty { Router.shared.lastRoute[previous] = hash }
        owner = tab
        if w.superview !== host {
            w.removeFromSuperview()
            w.frame = host.bounds
            w.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(w)
        }
        go(route)
    }

    /// Takes the page to a route of the web app without reloading it.
    func go(_ route: String) {
        guard let web, route != hash else { return }
        hash = route
        if web.isLoading || web.url == nil {
            web.load(URLRequest(url: Self.url(for: route)))  // the same page: only its address after # changes
        } else {
            let js = "if (location.hash !== \(String(reflecting: route))) location.hash = \(String(reflecting: route));"
            web.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    fileprivate func pageMoved(to newHash: String) {
        hash = newHash
        // a link inside the web app to Explore (its breadcrumbs, its logo) opens the native one
        if newHash.isEmpty || newHash == "#/" || newHash.hasPrefix("#/explore") {
            Router.shared.tab = .explore
        }
    }

    private static func url(for route: String) -> URL {
        // ?app=1: the web app's own in-app mode (iopix 1.77 and later) hides its bar and side menu and reports its
        // routes; the injected script above does the same for older servers
        URL(string: AppConfig.serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/?app=1" + route) ?? AppConfig.serverURL
    }

    final class Relay: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let h = message.body as? String ?? ""
            MainActor.assumeIsolated { WebShell.shared.pageMoved(to: h) }
        }
    }
}

/// A place in a tab where the shared web view appears while the tab is on screen.
struct WebTab: UIViewRepresentable {
    let tab: AppTab
    let route: String

    func makeUIView(context: Context) -> Host {
        let h = Host()
        h.tab = tab
        h.route = route
        return h
    }

    func updateUIView(_ host: Host, context: Context) {
        let changed = host.route != route
        host.route = route
        if changed, host.window != nil { WebShell.shared.adopt(into: host, tab: tab, route: route) }
    }

    final class Host: UIView {
        var tab: AppTab = .photos
        var route = ""

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            MainActor.assumeIsolated { WebShell.shared.adopt(into: self, tab: tab, route: route) }
        }
    }
}

/// A web tab: the web app at the tab's page, with the "can't reach iopix" notice over it when the server is out of
/// reach.
struct WebTabView: View {
    let tab: AppTab
    var route: String?
    @EnvironmentObject private var router: Router
    @ObservedObject private var status = WebShell.shared.status
    var changeServer: () -> Void = {}

    var body: some View {
        WebTab(tab: tab, route: route ?? router.lastRoute[tab] ?? tab.home)
            .ignoresSafeArea(edges: .bottom)
            .background(Color(.systemBackground))
            .overlay {
                if let why = status.failed {
                    VStack(spacing: 16) {
                        Image("Mark").resizable().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 16))
                        Text("Can't reach iopix").font(.title3.bold())
                        Text(why).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Text("It tries again by itself when the connection changes.").font(.footnote).foregroundStyle(.secondary)
                        Button("Try again") { status.retry() }.buttonStyle(.borderedProminent)
                        Button("Change server", action: changeServer).font(.footnote)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
                }
            }
    }
}
