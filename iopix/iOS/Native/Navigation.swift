import SwiftUI

/// The tabs at the bottom (a sidebar on iPad), all native.
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
    case settings, tools, consistency
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

    /// Opens a screen on top of whatever the tab on screen shows.
    func push(_ screen: Screen) {
        switch tab {
        case .explore, .photos: photosPath.append(screen); tab = .photos
        case .people: peoplePath.append(screen)
        case .places: placesPath.append(screen)
        case .more: morePath.append(screen)
        }
    }

    /// Opens an address in the web app's style ("#/photos?year=2020", from a widget, Spotlight or a notification) as
    /// the native screen for it, in the tab it belongs to.
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
        case "photos":  // one photo (#/photos?p=12): the list it is in, or the photo alone
            let p = query.value("p") ?? ""
            let rest = query.filters.filter { $0.name != "p" }
            let list = rest.isEmpty ? PhotoQuery([("ids", p)]) : PhotoQuery(rest)
            photosPath = [.photos(list)]
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
             "settings", "tools", "consistency", "datesuggest", "placesuggest", "jerseys", "clothing", "rotation", "damaged":
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
            default: screen = .tools
            }
            morePath = [screen]
            tab = .more
        default:
            tab = .explore  // a page the app has no screen for
        }
    }
}

