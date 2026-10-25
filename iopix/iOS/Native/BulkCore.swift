import SwiftUI

/// Writes to the server for the grid's tools (filters, saved searches, bulk actions). Every change is the server's;
/// the app only asks.
enum BulkAPI {
    /// A JSON request to the server; its JSON answer, or the server's own reason for refusing.
    @discardableResult
    static func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var r = IopixClient.shared.request(path, method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await IopixClient.shared.session.data(for: r)
        return try IopixClient.shared.check(data, resp)
    }

    /// A form-encoded request (the zip routes take a photo filter as form fields).
    static func form(_ path: String, _ items: [URLQueryItem]) -> URLRequest {
        var r = IopixClient.shared.request(path, method: "POST")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = items
        r.httpBody = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return r
    }

    static func ints(_ v: Any?) -> [Int] { (v as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue } }
}

/// What the grid's tools need to know about the library and the server, read once and kept up to date: every tag
/// and folder with its path, cameras, lenses, photographers, places, your albums (and which you can change), the saved
/// searches, and whether this server lets you edit.
@MainActor
final class BulkCatalog: ObservableObject {
    static let shared = BulkCatalog()

    struct Tag: Identifiable, Hashable {
        let id: Int, pid: Int?, name: String, full: String, person: Bool, all: Int, icon: Int?
        /// "Activity › Birthday Party", the last two parts, as the web app's filter shows them.
        var shortPath: String { full.split(separator: "/").suffix(2).joined(separator: " › ") }
    }
    struct Folder: Identifiable, Hashable {
        let id: Int, pid: Int?, name: String, path: String, all: Int
    }
    struct Album: Identifiable, Hashable {
        let id: Int, name: String, count: Int, shared: Bool, canEdit: Bool
    }
    struct Search: Identifiable, Hashable {
        let id: Int, name: String, query: String
    }
    struct PlaceRow: Hashable {
        let city: String, region: String?, country: String?, count: Int
    }

    @Published private(set) var tags: [Tag] = []
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var cameras: [(String, Int)] = []
    @Published private(set) var lenses: [(String, Int)] = []
    @Published private(set) var creators: [(String, Int)] = []
    @Published private(set) var places: [PlaceRow] = []
    @Published private(set) var concepts: [(String, Int)] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var searches: [Search] = []
    @Published private(set) var canShareAlbums = false
    @Published private(set) var canPrivateAlbums = false
    /// Editing metadata (sidecars) is on for this server and account.
    @Published private(set) var editing = false
    /// Moving, renaming and trashing files too (editing plus database writes).
    @Published private(set) var canManage = false
    @Published private(set) var lossless = false
    @Published private(set) var signedIn = false
    /// Content search ("photos that look like…") is on for this server.
    @Published private(set) var semantic = false
    @Published private(set) var canWrite = false
    @Published private(set) var recentTags: [Int] = []
    private var loadedAt: Date?

    private(set) var tagByID: [Int: Tag] = [:]
    private(set) var folderByID: [Int: Folder] = [:]

    /// Reads it all (again only when it is over a minute old, unless `force`).
    func load(force: Bool = false) async {
        if !force, let t = loadedAt, Date().timeIntervalSince(t) < 60 { return }
        loadedAt = Date()
        async let m = try? IopixClient.shared.json("api/meta")
        async let st = try? IopixClient.shared.json("api/status")
        async let c = try? IopixClient.shared.json("api/concepts")
        if let meta = await m { apply(meta: meta) }
        if let s = await st {
            editing = s["editing"] as? Bool ?? false
            canManage = editing && (s["dbWrite"] as? Bool ?? false)
            lossless = s["lossless"] != nil && !(s["lossless"] is NSNull)
            signedIn = s["user"] is [String: Any]
            semantic = (s["semantic"] as? [String: Any])?["enabled"] as? Bool ?? false
        }
        if let a = try? await IopixClient.shared.account() { canWrite = a.canWrite }
        if let cj = await c, cj["enabled"] as? Bool != false {
            concepts = (cj["concepts"] as? [[String: Any]] ?? []).compactMap { x in
                guard let n = x["name"] as? String else { return nil }
                return (n, (x["n"] as? NSNumber)?.intValue ?? 0)
            }
        }
        await loadState()
    }

    /// Albums and saved searches (after a change to them).
    func loadState() async {
        guard let s = try? await IopixClient.shared.json("api/state") else { return }
        albums = (s["albums"] as? [[String: Any]] ?? []).compactMap { a in
            guard let id = (a["id"] as? NSNumber)?.intValue else { return nil }
            return Album(id: id, name: a["name"] as? String ?? "", count: (a["n"] as? NSNumber)?.intValue ?? 0,
                         shared: a["shared"] as? Bool ?? true, canEdit: a["canEdit"] as? Bool ?? true)
        }
        searches = (s["searches"] as? [[String: Any]] ?? []).compactMap { x in
            guard let id = (x["id"] as? NSNumber)?.intValue else { return nil }
            return Search(id: id, name: x["name"] as? String ?? "", query: x["query"] as? String ?? "")
        }
        canShareAlbums = s["canShareAlbums"] as? Bool ?? false
        canPrivateAlbums = s["canPrivateAlbums"] as? Bool ?? false
    }

    func loadRecentTags() async {
        guard let m = try? await IopixClient.shared.json("api/maintenance") else { return }
        recentTags = BulkAPI.ints(m["recentTags"])
    }

    func noteRecent(_ ids: [Int]) async {
        if let r = try? await BulkAPI.post("api/tags/recent", ["ids": ids]) { recentTags = BulkAPI.ints(r["recent"]) }
    }

    private func apply(meta: [String: Any]) {
        func pairs(_ k: String) -> [(String, Int)] {
            (meta[k] as? [[Any]] ?? []).compactMap { p in
                guard p.count >= 2, let s = p[0] as? String, let n = (p[1] as? NSNumber)?.intValue else { return nil }
                return (s, n)
            }
        }
        tags = (meta["tags"] as? [[String: Any]] ?? []).compactMap { t in
            guard let id = (t["id"] as? NSNumber)?.intValue else { return nil }
            return Tag(id: id, pid: (t["pid"] as? NSNumber)?.intValue, name: (t["name"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                       full: t["full"] as? String ?? "", person: (t["person"] as? NSNumber)?.boolValue ?? false,
                       all: (t["nAll"] as? NSNumber)?.intValue ?? 0, icon: (t["icon"] as? NSNumber)?.intValue)
        }
        folders = (meta["albums"] as? [[String: Any]] ?? []).compactMap { a in
            guard let id = (a["id"] as? NSNumber)?.intValue else { return nil }
            return Folder(id: id, pid: (a["pid"] as? NSNumber)?.intValue, name: a["name"] as? String ?? "",
                          path: a["path"] as? String ?? "", all: (a["nAll"] as? NSNumber)?.intValue ?? 0)
        }
        tagByID = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        folderByID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        cameras = pairs("cameras"); lenses = pairs("lenses"); creators = pairs("creators")
        places = (meta["places"] as? [[Any]] ?? []).compactMap { p in
            guard p.count >= 4, let city = p[0] as? String, let n = (p[3] as? NSNumber)?.intValue else { return nil }
            return PlaceRow(city: city, region: p[1] as? String, country: p[2] as? String, count: n)
        }
    }
}

extension PhotoQuery {
    func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }

    func has(_ name: String, _ value: String) -> Bool { values(name).contains(value) }

    /// Adds the value to a key that may have several (tag, album, camera...), or takes it out when it is there.
    func toggling(_ name: String, _ value: String) -> PhotoQuery {
        var q = self
        if has(name, value) { q.items.removeAll { $0.name == name && $0.value == value } }
        else { q.items.append(URLQueryItem(name: name, value: value)) }
        return q
    }

    /// One value for a key; choosing the value it already has clears it (as the web app's filter does).
    func choosing(_ name: String, _ value: String?) -> PhotoQuery {
        if let value, self.value(name) == value { return setting(name, nil) }
        return setting(name, value)
    }

    func removing(_ name: String, _ value: String) -> PhotoQuery {
        var q = self
        q.items.removeAll { $0.name == name && $0.value == value }
        return q
    }

    func adding(_ name: String, _ value: String) -> PhotoQuery {
        var q = self
        q.items.append(URLQueryItem(name: name, value: value))
        return q
    }

    /// The filters as the web app writes them after #/photos? (the order of the photos left out).
    var queryString: String {
        var c = URLComponents()
        c.queryItems = filters
        return c.percentEncodedQuery ?? ""
    }

    /// Same filters, whatever their order (for matching a saved search).
    var key: String { filters.map { "\($0.name)=\($0.value ?? "")" }.sorted().joined(separator: "&") }

    /// A saved search's query as the web app stores it (URLSearchParams writes a space as "+", which URLComponents
    /// would keep as a plus).
    static func saved(_ query: String) -> PhotoQuery { PhotoQuery(query: query.replacingOccurrences(of: "+", with: "%20")) }
}

/// A filter shown as a chip: what it says, and how to drop it.
struct FilterChip: Identifiable, Hashable {
    let name: String, value: String, label: String, symbol: String, face: Int?
    var id: String { name + "=" + value }
}

extension BulkCatalog {
    private static let months = Calendar(identifier: .gregorian).monthSymbols

    /// The chips for a list's filters, worded as the web app's.
    func chips(_ q: PhotoQuery) -> [FilterChip] {
        var out: [FilterChip] = []
        func add(_ k: String, _ v: String, _ label: String, _ symbol: String = "line.3.horizontal.decrease", face: Int? = nil) {
            out.append(FilterChip(name: k, value: v, label: label, symbol: symbol, face: face))
        }
        for item in q.filters {
            let k = item.name, v = item.value ?? ""
            switch k {
            case "q": add(k, v, "“\(v)”", "text.magnifyingglass")
            case "tag", "nottag":
                let t = Int(v).flatMap { tagByID[$0] }
                add(k, v, (k == "nottag" ? "Not " : "") + (t?.name ?? "Tag \(v)"), t?.person == true ? "person.crop.circle" : "tag", face: t?.person == true ? t?.id : nil)
            case "album": add(k, v, Int(v).flatMap { folderByID[$0]?.name } ?? "Folder \(v)", "folder")
            case "year": add(k, v, v, "calendar")
            case "month": add(k, v, Int(v).flatMap { $0 >= 1 && $0 <= 12 ? Self.months[$0 - 1] : nil } ?? v, "calendar")
            case "from": add(k, v, "From \(v)", "calendar")
            case "to": add(k, v, "Until \(v)", "calendar")
            case "md":
                let p = v.split(separator: "-").compactMap { Int($0) }
                add(k, v, p.count == 2 && (1...12).contains(p[0]) ? "On \(Self.months[p[0] - 1]) \(p[1]), any year" : v, "calendar")
            case "camera", "lens": add(k, v, v == "~" ? "No \(k)" : v, "camera")
            case "fmt": add(k, v, v, "doc")
            case "creator": add(k, v, "By \(v)", "c.circle")
            case "rating": add(k, v, "\(v)★ and up", "star")
            case "pick": add(k, v, ["No pick label", "Rejected", "Pending", "Accepted"][min(max(Int(v) ?? 0, 0), 3)], "flag")
            case "color": add(k, v, "Colour: \(Self.colorNames[min(max(Int(v) ?? 0, 0), 9)])", "paintpalette")
            case "type": add(k, v, v == "video" ? "Videos" : "Photos only", v == "video" ? "video" : "photo")
            case "geo": add(k, v, v == "1" ? "Has location" : "No location", "mappin")
            case "untagged": add(k, v, "Untagged", "tag.slash")
            case "bbox": add(k, v, "Map area", "map")
            case "trail": add(k, v, "Trail for \(v)", "map")
            case "faces":
                add(k, v, ["unknown": "Unnamed faces", "suggested": "Face suggestions", "ignored": "Ignored faces", "confirmed": "Named faces"][v] ?? v, "face.smiling")
            case "fav": add(k, v, "Favorites", "heart")
            case "ualbum": add(k, v, Int(v).flatMap { id in albums.first { $0.id == id }?.name } ?? "Album", "rectangle.stack")
            case "place", "region", "country": add(k, v, v, "mappin.and.ellipse")
            case "sem": add(k, v, "Looks like “\(v)”", "sparkles")
            case "like": add(k, v, "Similar photos", "square.on.square")
            case "concept": add(k, v, "Detected: \(v)", "sparkles")
            case "blurry": add(k, v, "Blurry", "camera.metering.unknown")
            case "sharpest": add(k, v, "Sharpest", "camera.aperture")
            case "exposure": add(k, v, v == "dark" ? "Very dark" : "Very bright", "sun.max")
            case "hastext": add(k, v, "Contains text", "text.viewfinder")
            case "bursts": add(k, v, "In a burst", "square.stack.3d.down.right")
            case "bestonly": add(k, v, "Best frame of each burst", "star.square.on.square")
            case "burst": add(k, v, "One burst", "square.stack.3d.down.right")
            case "obj": add(k, v, "Shows: \(v)", "sparkles")
            case "npeople": add(k, v, v == "0" ? "No people" : "\(v) \(v == "1" ? "person" : "people")", "person.2")
            case "dupes": add(k, v, "Duplicates", "doc.on.doc")
            case "edited": add(k, v, "Edited here, not yet in digiKam", "pencil")
            case "ids": add(k, v, "\(v.split(separator: ",").count.formatted()) chosen photos", "checkmark.circle")
            default:
                let parts = k.split(separator: "_")
                if parts.count == 2, ["iso", "ap", "fl", "exp"].contains(String(parts[0])), ["min", "max"].contains(String(parts[1])) {
                    let label = ["iso": "ISO", "ap": "ƒ/", "fl": "Focal mm", "exp": "Exposure s"][String(parts[0])] ?? ""
                    add(k, v, "\(label) \(parts[1] == "min" ? "≥" : "≤") \(v)", "camera.aperture")
                }
            }
        }
        return out
    }

    /// digiKam's colour labels, in its order (0 is none).
    static let colorNames = ["None", "Red", "Orange", "Yellow", "Green", "Blue", "Magenta", "Gray", "Black", "White"]
    static let colorValues: [Color] = [.clear, .red, .orange, .yellow, .green, .blue, Color(red: 0.85, green: 0.2, blue: 0.75), .gray, .black, .white]
}

/// The filters of a list as chips under its title, each with a cross to drop it.
struct FilterChips: View {
    @Binding var query: PhotoQuery
    @ObservedObject private var catalog = BulkCatalog.shared

    var body: some View {
        let chips = catalog.chips(query)
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips) { c in
                        HStack(spacing: 6) {
                            if let f = c.face {
                                RemoteImage(path: "face/\(f)?v=\(catalog.tagByID[f]?.icon ?? 0)").frame(width: 20, height: 20).clipShape(Circle())
                            } else {
                                Image(systemName: c.symbol).font(.caption)
                            }
                            Text(c.label).font(.subheadline).lineLimit(1)
                            Button { query = query.removing(c.name, c.value) } label: {
                                Image(systemName: "xmark.circle.fill").font(.subheadline).foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("Remove \(c.label)")
                        }
                        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    if chips.count > 1 {
                        Button("Clear all") { query = PhotoQuery(query.items.filter { $0.name == "sort" }) }.font(.subheadline)
                    }
                }
            }
        }
    }
}
