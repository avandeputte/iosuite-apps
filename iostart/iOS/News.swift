import Foundation

// The start page's feed reader (`/api/news…`, iostart/news/api.py in the iosuite repo), as the Feeds page of the
// start page uses it: the same feeds, the same articles read and starred.

/// A feed the person follows.
struct Feed: Codable, Identifiable, Hashable {
    var id: Int
    var title: String
    var feedTitle: String?
    var url: String?
    var site: String?
    var folder: String
    var onStart: Bool
    var unread: Int
    var error: String?
    /// Where the start page serves the site's icon, relative to its address ("" when it has none).
    var icon: String?

    enum CodingKeys: String, CodingKey { case id, title, feedTitle, url, site, folder, onStart, unread, error, icon }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        feedTitle = try? c.decodeIfPresent(String.self, forKey: .feedTitle)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        site = try? c.decodeIfPresent(String.self, forKey: .site)
        folder = (try? c.decodeIfPresent(String.self, forKey: .folder)) ?? ""
        onStart = (try? c.decodeIfPresent(Bool.self, forKey: .onStart)) ?? false
        unread = (try? c.decodeIfPresent(Int.self, forKey: .unread)) ?? 0
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        icon = try? c.decodeIfPresent(String.self, forKey: .icon)
    }
}

/// The answer of GET /api/news.
struct FeedsOverview: Codable {
    var feeds: [Feed]
    var folders: [String]
    var unread: Int
    var starred: Int

    enum CodingKeys: String, CodingKey { case feeds, folders, unread, starred }
    init(feeds: [Feed] = [], folders: [String] = [], unread: Int = 0, starred: Int = 0) {
        self.feeds = feeds; self.folders = folders; self.unread = unread; self.starred = starred
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feeds = (try? c.decodeIfPresent([Feed].self, forKey: .feeds)) ?? []
        folders = (try? c.decodeIfPresent([String].self, forKey: .folders)) ?? []
        unread = (try? c.decodeIfPresent(Int.self, forKey: .unread)) ?? 0
        starred = (try? c.decodeIfPresent(Int.self, forKey: .starred)) ?? 0
    }
}

/// An article, as the lists have it; with `html` when asked for by itself.
struct Article: Codable, Identifiable, Hashable {
    var id: Int
    var title: String
    var link: String?
    var author: String?
    var at: Double?
    var text: String?
    var image: String?
    var audio: String?
    var feedId: Int?
    var feed: String?
    var read: Bool
    var starred: Bool
    var html: String?

    enum CodingKeys: String, CodingKey { case id, title, link, author, at, text, image, audio, feedId, feed, read, starred, html }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "(no title)"
        link = try? c.decodeIfPresent(String.self, forKey: .link)
        author = try? c.decodeIfPresent(String.self, forKey: .author)
        at = try? c.decodeIfPresent(Double.self, forKey: .at)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        image = try? c.decodeIfPresent(String.self, forKey: .image)
        audio = try? c.decodeIfPresent(String.self, forKey: .audio)
        feedId = try? c.decodeIfPresent(Int.self, forKey: .feedId)
        feed = try? c.decodeIfPresent(String.self, forKey: .feed)
        read = (try? c.decodeIfPresent(Bool.self, forKey: .read)) ?? false
        starred = (try? c.decodeIfPresent(Bool.self, forKey: .starred)) ?? false
        html = try? c.decodeIfPresent(String.self, forKey: .html)
    }

    var date: Date? { at.map { Date(timeIntervalSince1970: $0) } }
    var linkURL: URL? { link.flatMap { URL(string: $0) } }

    /// "5 min", "3 h", "2 d", "12 Nov": how long ago, short, as the Feeds page writes it.
    var ago: String {
        guard let date else { return "" }
        let s = Date().timeIntervalSince(date)
        if s < 3600 { return "\(max(1, Int((s / 60).rounded()))) min" }
        if s < 86400 { return "\(Int((s / 3600).rounded())) h" }
        if s < 7 * 86400 { return "\(Int((s / 86400).rounded())) d" }
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date())
        return sameYear ? date.formatted(.dateTime.day().month(.abbreviated)) : date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// Which articles a list shows: everything, the starred ones, a folder's or a feed's.
enum NewsScope: Hashable {
    case all
    case starred
    case folder(String)
    case feed(Int)
}

/// Unread, all or starred.
enum NewsShow: String, CaseIterable, Identifiable {
    case unread, all, starred
    var id: String { rawValue }
    var label: String { self == .unread ? "Unread" : self == .all ? "All" : "Starred" }
}

extension API {
    struct ArticlePage: Decodable { var items: [Article]; var next: String? }
    struct Followed: Decodable { var feed: Feed; var new: Bool? }
    struct Looked: Decodable { var checked: Int?; var new: Int? }
    struct Done: Decodable { var ok: Bool? }

    private static func query(_ pairs: [(String, String)]) -> String {
        var c = URLComponents()
        c.queryItems = pairs.filter { !$0.1.isEmpty }.map { URLQueryItem(name: $0.0, value: $0.1) }
        // a + in a query is read as a space by the server: written out
        return (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    func feeds() async throws -> FeedsOverview { try await call("GET", "/api/news") }

    func articles(_ scope: NewsScope, show: NewsShow, search: String = "", before: String? = nil) async throws -> ArticlePage {
        var q: [(String, String)] = [("show", scope == .starred ? "starred" : show.rawValue), ("q", search), ("before", before ?? "")]
        switch scope {
        case .feed(let id): q.append(("feed", String(id)))
        case .folder(let name): q.append(("folder", name))
        case .all, .starred: break
        }
        return try await call("GET", "/api/news/items?" + API.query(q))
    }

    /// One article with its text (`html`, cleaned by the server).
    func article(_ id: Int) async throws -> Article { try await call("GET", "/api/news/items/\(id)") }

    private struct Mark: Encodable { var ids: [Int]; var read: Bool?; var starred: Bool? }
    func mark(_ ids: [Int], read: Bool? = nil, starred: Bool? = nil) async throws {
        let _: Done = try await call("POST", "/api/news/items/mark", body: try JSONEncoder().encode(Mark(ids: ids, read: read, starred: starred)))
    }

    private struct AllRead: Encodable { var feed: Int?; var folder: String?; var upto: Int? }
    /// Everything of the scope read, up to the newest article the list was showing.
    func markAllRead(_ scope: NewsScope, upto: Int?) async throws {
        var b = AllRead(upto: upto)
        if case .feed(let id) = scope { b.feed = id }
        if case .folder(let name) = scope { b.folder = name }
        let _: Done = try await call("POST", "/api/news/read", body: try JSONEncoder().encode(b))
    }

    /// Has the start page look at the feeds now (those not looked at in the last two minutes).
    func lookForNews() async throws -> Looked { try await call("POST", "/api/news/refresh") }

    private struct Follow: Encodable { var url: String; var folder: String }
    /// Follow a feed by its address, or its site's (the start page finds the feed).
    func follow(_ url: String, folder: String) async throws -> Followed {
        try await call("POST", "/api/news/feeds", body: try JSONEncoder().encode(Follow(url: url, folder: folder)))
    }

    struct FeedChange: Encodable { var title: String; var folder: String; var onStart: Bool }
    func change(_ feed: Int, _ c: FeedChange) async throws {
        let _: Done = try await call("PATCH", "/api/news/feeds/\(feed)", body: try JSONEncoder().encode(c))
    }

    func unfollow(_ feed: Int) async throws {
        let _: Done = try await call("DELETE", "/api/news/feeds/\(feed)")
    }
}
