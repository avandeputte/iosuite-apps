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

/// A list of photos the server can give: the same filters as the web app's Photos page (tag, year, place,
/// from/to, fav, type, q...).
struct PhotoQuery: Hashable {
    var items: [URLQueryItem] = []

    init(_ items: [URLQueryItem] = []) { self.items = items }

    init(_ pairs: [(String, String)]) { items = pairs.map { URLQueryItem(name: $0.0, value: $0.1) } }

    /// From the part of a web address after ? ("tag=12&sort=old").
    init(query: String) {
        var c = URLComponents()
        c.percentEncodedQuery = query
        items = c.queryItems ?? []
    }

    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

    func setting(_ name: String, _ value: String?) -> PhotoQuery {
        var q = self
        q.items.removeAll { $0.name == name }
        if let value { q.items.append(URLQueryItem(name: name, value: value)) }
        return q
    }

    /// The filters a person chose (not the order).
    var filters: [URLQueryItem] { items.filter { $0.name != "sort" } }
}

/// A native screen a link can lead to, inside a tab.
enum Screen: Hashable {
    case photos(PhotoQuery, title: String? = nil)
    case folders(parent: Int?)
    case albums
    case tags(parent: Int?)
    case events
    case map
    case trash, importPhotos, duplicates, nearDuplicates, detected, quality, dateSuggest
    case placeSuggest, jerseys, clothing, rotation, damaged
    case history(photo: Int?)
    case faces(String)
    case settings, maintenance, consistency
    case web(String)
}

/// Which tab is showing, and the screens opened in each.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()

    @Published var tab: AppTab = .explore
    @Published var photosPath: [Screen] = []
    @Published var peoplePath: [Screen] = []
    @Published var placesPath: [Screen] = []
    @Published var morePath: [Screen] = []
    @Published var placesShowsMap = true
    /// The level of Places on show: a country, then one of its regions (nil: the countries).
    @Published var placesCountry: String?
    @Published var placesRegion: String?
    /// The filters the map in Places is limited to ("Show these on the map", a day's trail); empty for every photo.
    @Published var mapQuery = PhotoQuery()
    var lastRoute: [AppTab: String] = [:]

    /// Opens a screen on top of whatever the tab on screen shows.
    func push(_ screen: Screen) {
        switch tab {
        case .explore, .photos: photosPath.append(screen); tab = .photos
        case .people: peoplePath.append(screen)
        case .places: placesPath.append(screen)
        case .more: morePath.append(screen)
        }
    }

    /// Opens an address of the web app ("#/photos?year=2020") as the native screen for it, in the tab it belongs
    /// to. Settings, Maintenance, editing a photo (#/photos?p=) and the other admin pages open the web app.
    func open(_ route: String) {
        let body = route.hasPrefix("#/") ? String(route.dropFirst(2)) : route
        let parts = body.split(separator: "?", maxSplits: 1).map(String.init)
        let view = parts.first.map { String($0.split(separator: "/").first ?? "") } ?? ""
        let query = PhotoQuery(query: parts.count > 1 ? parts[1] : "")
        switch view {
        case "", "explore":
            tab = .explore
        case "photos" where query.value("p") == nil:
            photosPath = query.filters.isEmpty ? [] : [.photos(query)]
            tab = .photos
        case "favorites":
            photosPath = [.photos(PhotoQuery([("fav", "1")]))]
            tab = .photos
        case "people":
            peoplePath = []
            tab = .people
        case "faces":
            peoplePath = [.faces(query.value("tab") ?? "suggested")]
            tab = .people
        case "places":
            // #/places?country=France&region=Normandy: that level of the list
            placesCountry = query.value("country")
            placesRegion = placesCountry == nil ? nil : query.value("region")
            placesShowsMap = false
            placesPath = []
            tab = .places
        case "map":
            // #/map?year=2020 ("Show these on the map"), #/map?from=D&to=D&trail=D (a day's trail): the map limited
            // to those photos
            mapQuery = PhotoQuery(query.filters)
            placesShowsMap = true
            placesPath = []
            tab = .places
        case "folders":
            morePath = [.folders(parent: nil)]
            tab = .more
        case "albums":
            morePath = [.albums]
            tab = .more
        case "tags":
            morePath = [.tags(parent: nil)]
            tab = .more
        case "events":
            morePath = [.events]
            tab = .more
        case "trash", "import", "duplicates", "neardups", "detected", "quality", "history",
             "settings", "maintenance", "analysis", "consistency", "datesuggest", "placesuggest", "jerseys", "clothing", "rotation", "damaged":
            let screen: Screen
            switch view {
            case "trash": screen = .trash
            case "import": screen = .importPhotos
            case "duplicates": screen = .duplicates
            case "neardups": screen = .nearDuplicates
            case "detected": screen = .detected
            case "quality": screen = .quality
            case "history": screen = .history(photo: query.value("photo").flatMap(Int.init))
            case "settings": screen = .settings
            case "consistency": screen = .consistency
            case "datesuggest": screen = .dateSuggest
            case "placesuggest": screen = .placeSuggest
            case "jerseys": screen = .jerseys
            case "clothing": screen = .clothing
            case "rotation": screen = .rotation
            case "damaged": screen = .damaged
            default: screen = .maintenance
            }
            morePath = [screen]
            tab = .more
        default:
            morePath = [.web(route)]
            tab = .more
        }
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
        // read when a cookie changes, not now: the web view can be made before the app has set `onCookiesChanged`
        let c = IopixWebView.Coordinator({ WebShell.shared.onCookiesChanged() }, status: status)
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
