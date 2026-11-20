import Foundation

/// The app's own links, as the widgets and the Shortcuts actions open it:
///
///     iostart://open?id=<bookmark id>    a bookmark, in the built-in browser (or the phone's, as Settings says)
///     iostart://open?url=<address>       a page: an event's day in ioCalendar, a task in ioTask
///     iostart://settings                 Settings (a widget that asks to sign in again)
enum DeepLink: Equatable {
    case bookmark(Int)
    case page(URL)
    case settings

    static let scheme = "iostart"

    var url: URL {
        var c = URLComponents()
        c.scheme = DeepLink.scheme
        c.host = "open"
        switch self {
        case .settings: c.host = "settings"
        case .bookmark(let id): c.queryItems = [URLQueryItem(name: "id", value: String(id))]
        case .page(let page): c.queryItems = [URLQueryItem(name: "url", value: page.absoluteString)]
        }
        return c.url ?? URL(string: "iostart://open")!
    }

    init?(_ url: URL) {
        if url.scheme?.lowercased() == DeepLink.scheme, url.host?.lowercased() == "settings" {
            self = .settings
            return
        }
        guard url.scheme?.lowercased() == DeepLink.scheme, url.host?.lowercased() == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        if let id = items.first(where: { $0.name == "id" })?.value.flatMap(Int.init) {
            self = .bookmark(id)
        } else if let s = items.first(where: { $0.name == "url" })?.value, let page = URL(string: s),
                  ["http", "https"].contains(page.scheme?.lowercased() ?? "") {
            self = .page(page)
        } else {
            return nil
        }
    }

    /// A link a Shortcuts action left for the app to open when it comes to the front (the action runs in the app's
    /// process, before or while its window shows).
    static var pending: DeepLink? {
        get { Shared.defaults.url(forKey: "pendingLink").flatMap(DeepLink.init) }
        set { Shared.defaults.set(newValue?.url, forKey: "pendingLink") }
    }
}

extension Notification.Name {
    /// A Shortcuts action left a link to open (DeepLink.pending).
    static let ioStartOpenLink = Notification.Name("net.iothing.iostart.openLink")
}
