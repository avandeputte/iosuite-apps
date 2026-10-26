import SwiftUI
import UIKit

/// A list of photos from iopix, as the web app gets it: ids in order, and which of them are videos.
/// A photo's date as people should read it. Times are the camera's clock kept as UTC. An approximate date has a
/// placeholder day (1 January, or the 1st of the month) that is never shown: only the part that is known.
enum PhotoDates {
    /// iopix's names ("month", "year", "unknown") as levels 1, 2, 3; nil for an exact date.
    static func level(_ name: String?) -> Int? { ["month": 1, "year": 2, "unknown": 3][name ?? ""] }
    static func name(_ level: Int?) -> String { [1: "month", 2: "year", 3: "unknown"][level ?? 0] ?? "exact" }

    static func text(_ ts: Double, precision: Int?, time: Bool = true) -> String {
        let d = Date(timeIntervalSince1970: ts)
        switch precision {
        case 3: return "Date unknown"
        case 2: return d.formatted(utc(.dateTime.year()))
        case 1: return d.formatted(utc(.dateTime.month(.wide).year()))
        default: return time ? d.formatted(utc(.dateTime.month(.abbreviated).day().year().hour().minute())) : d.formatted(utc(.dateTime.month(.abbreviated).day().year()))
        }
    }

    static func utc(_ f: Date.FormatStyle) -> Date.FormatStyle {
        var f = f
        f.timeZone = TimeZone(identifier: "UTC")!
        return f
    }
}

struct PhotoList: Equatable {
    var ids: [Int] = []
    var videos: Set<Int> = []  // positions in ids
    var times: [Double] = []   // when each was taken (seconds since 1970), when known
    var ratios: [Double] = []  // width / height of each, when known (for rows of photos at their own shape)
    var ranked = false         // a search by meaning: the server's order is best match first
    var geo: Set<Int> = []     // positions with a location
    var faces: Set<Int> = []   // positions with a named face
    var durations: [Int: Int] = [:]  // position of a video -> its length in seconds, when known
    /// Positions whose date is only partly known (iopix 1.80): 1 month and year, 2 year only, 3 unknown.
    var precision: [Int: Int] = [:]

    /// The date of the photo at `i` as far as it is known ("May 1992", "1992", "Date unknown"), nil when its time is
    /// not in the list.
    func dateText(_ i: Int) -> String? {
        guard i < times.count, times[i] > 0 || precision[i] == 3 else { return nil }
        return PhotoDates.text(times[i], precision: precision[i])
    }

    func hasLocation(_ i: Int) -> Bool { geo.contains(i) }
    func hasFaces(_ i: Int) -> Bool { faces.contains(i) }

    func ratio(_ i: Int) -> Double { i < ratios.count ? ratios[i] : 1.5 }

    func isVideo(_ i: Int) -> Bool { videos.contains(i) }

    static func load(_ query: [URLQueryItem]) async throws -> PhotoList {
        PhotoList(json: try await IopixClient.shared.json("api/photos", query: query))
    }

    /// From any answer that lists photos the way api/photos does (api/random too).
    init(json j: [String: Any]) {
        ids = (j["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        videos = Set((j["video"] as? [String: Any] ?? [:]).keys.compactMap(Int.init))
        times = (j["ts"] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        ranked = j["ranked"] as? Bool ?? false
        geo = Set((j["geo"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue })
        faces = Set((j["faces"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue })
        for (k, v) in j["video"] as? [String: Any] ?? [:] {
            if let i = Int(k), let d = (v as? NSNumber)?.intValue, d > 0 { durations[i] = d }
        }
        for (k, v) in j["dp"] as? [String: Any] ?? [:] {
            if let i = Int(k), let p = (v as? NSNumber)?.intValue, p > 0 { precision[i] = p }
        }
        let w = (j["w"] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        let h = (j["h"] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        ratios = zip(w, h).map { w, h in h > 0 && w > 0 ? min(2.2, max(0.5, w / h)) : 1.5 }
    }

    init(ids: [Int] = [], videos: Set<Int> = [], times: [Double] = []) {
        self.ids = ids; self.videos = videos; self.times = times
    }
}

struct Folder: Identifiable, Hashable {
    let id: Int
    let parent: Int?
    let name: String
    let count: Int
    let cover: Int?
}

struct Person: Identifiable, Hashable {
    let id: Int
    let name: String
    let count: Int
    let face: Int?
    var all = 0          // photos with them, sub-tags included (what the web app shows)
    var icon: Int? = nil // version of their face picture
    var cover: Int? = nil
}

/// The numbers and lists the library summary has, for Explore.
struct LibrarySummary: Equatable {
    var total = 0, videos = 0, geotagged = 0
    var bytes: Int64 = 0
    var folders = 0
    var years: [(Int, Int)] = []
    var cameras: [(String, Int)] = []
    var creators: [(String, Int)] = []
    var formats: [(String, Int)] = []
    var ratings: [(Int, Int)] = []
    var things: [TagItem] = []  // the top tags, as the web app's Explore lists them

    static func == (a: LibrarySummary, b: LibrarySummary) -> Bool {
        a.total == b.total && a.videos == b.videos && a.bytes == b.bytes && a.things == b.things && a.years.map(\.0) == b.years.map(\.0)
    }

    func count(rating: Int) -> Int { ratings.first { $0.0 == rating }?.1 ?? 0 }
    var threeAndUp: Int { ratings.filter { $0.0 >= 3 }.reduce(0) { $0 + $1.1 } }
}

struct Place: Identifiable, Hashable {
    let name: String
    let region: String?
    let country: String?
    let count: Int
    let cover: Int?
    var id: String { [name, region ?? "", country ?? ""].joined(separator: "|") }
}

/// A tag of the library that is not a person (Activity, Food, Where/Paris...), shown like an album. Its count
/// includes the photos of its sub-tags, as the server's tag search does.
struct TagItem: Identifiable, Hashable {
    let id: Int
    let parent: Int?
    let name: String
    let count: Int
    let cover: Int?
}

struct Album: Identifiable, Hashable {
    let id: Int
    let name: String
    let count: Int
    let cover: Int?
}

/// What iopix has: folders, people, years, albums. Read once per launch (and on demand).
@MainActor
final class LibraryStore: ObservableObject {
    @Published var folders: [Folder] = []
    @Published var people: [Person] = []
    @Published var years: [(year: Int, count: Int)] = []
    @Published var albums: [Album] = []
    @Published var favorites = 0
    @Published var favoriteIDs: Set<Int> = []
    @Published var places: [Place] = []
    @Published var tags: [TagItem] = []
    @Published var summary = LibrarySummary()
    @Published var loaded = false
    @Published var needsSignIn = false
    @Published var problem: String?

    /// The tags shown under a tag (nil: the top ones), most photos first.
    func tags(under parent: Int?) -> [TagItem] {
        let ids = Set(tags.map(\.id))
        return tags.filter { parent == nil ? ($0.parent == nil || !ids.contains($0.parent!)) : $0.parent == parent }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func load() async {
        do {
            let meta = try await IopixClient.shared.json("api/meta")
            folders = (meta["albums"] as? [[String: Any]] ?? []).compactMap { a in
                guard let id = (a["id"] as? NSNumber)?.intValue else { return nil }
                return Folder(id: id, parent: (a["pid"] as? NSNumber)?.intValue, name: a["name"] as? String ?? "",
                              count: (a["nAll"] as? NSNumber)?.intValue ?? 0, cover: (a["cover"] as? NSNumber)?.intValue)
            }
            people = (meta["tags"] as? [[String: Any]] ?? []).compactMap { t in
                guard (t["person"] as? NSNumber)?.boolValue == true, let id = (t["id"] as? NSNumber)?.intValue,
                      let n = (t["n"] as? NSNumber)?.intValue, n > 0 else { return nil }
                return Person(id: id, name: t["name"] as? String ?? "", count: n, face: (t["face"] as? NSNumber)?.intValue,
                              all: (t["nAll"] as? NSNumber)?.intValue ?? n, icon: (t["icon"] as? NSNumber)?.intValue,
                              cover: (t["cover"] as? NSNumber)?.intValue)
            }.sorted { $0.count > $1.count }
            tags = Self.tags(from: meta["tags"] as? [[String: Any]] ?? [])
            summary = Self.summary(from: meta)
            years = (meta["years"] as? [[Any]] ?? []).compactMap { y in
                guard y.count == 2, let year = (y[0] as? NSNumber)?.intValue, let n = (y[1] as? NSNumber)?.intValue else { return nil }
                return (year, n)
            }
            let st = try await IopixClient.shared.json("api/state")
            albums = (st["albums"] as? [[String: Any]] ?? []).compactMap { a in
                guard let id = (a["id"] as? NSNumber)?.intValue else { return nil }
                return Album(id: id, name: a["name"] as? String ?? "", count: (a["n"] as? NSNumber)?.intValue ?? 0,
                             cover: (a["cover"] as? NSNumber)?.intValue)
            }
            let fav = (st["favorites"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            favoriteIDs = Set(fav)
            favorites = fav.count
            places = (meta["places"] as? [[Any]] ?? []).compactMap { p in
                guard p.count >= 5, let name = p[0] as? String, let n = (p[3] as? NSNumber)?.intValue else { return nil }
                return Place(name: name, region: p[1] as? String, country: p[2] as? String, count: n, cover: (p[4] as? NSNumber)?.intValue)
            }
            problem = nil
            needsSignIn = false
            loaded = true
        } catch IopixError.needsSignIn {
            needsSignIn = true
            problem = IopixError.needsSignIn.localizedDescription
        } catch {
            problem = error.localizedDescription
        }
    }

    private static func summary(from m: [String: Any]) -> LibrarySummary {
        func int(_ k: String) -> Int { (m[k] as? NSNumber)?.intValue ?? 0 }
        func pairs(_ k: String) -> [(String, Int)] {
            (m[k] as? [[Any]] ?? []).compactMap { p in
                guard p.count >= 2, let n = (p[1] as? NSNumber)?.intValue else { return nil }
                return ((p[0] as? String) ?? (p[0] as? NSNumber)?.stringValue ?? "", n)
            }
        }
        var s = LibrarySummary()
        s.total = int("total"); s.videos = int("videos"); s.geotagged = int("geotagged")
        s.bytes = (m["bytes"] as? NSNumber)?.int64Value ?? 0
        s.folders = (m["albums"] as? [Any])?.count ?? 0
        s.years = pairs("years").compactMap { p in Int(p.0).map { ($0, p.1) } }
        s.cameras = pairs("cameras"); s.creators = pairs("creators"); s.formats = pairs("formats")
        s.ratings = pairs("ratings").compactMap { p in Int(p.0).map { ($0, p.1) } }
        // the top tags with photos, as the web app's Things (a person at the top with no tags under it is not one)
        let raw = m["tags"] as? [[String: Any]] ?? []
        let parents = Set(raw.compactMap { ($0["pid"] as? NSNumber)?.intValue })
        s.things = raw.compactMap { t -> TagItem? in
            guard t["pid"] == nil || t["pid"] is NSNull, let id = (t["id"] as? NSNumber)?.intValue,
                  let all = (t["nAll"] as? NSNumber)?.intValue, all > 0 else { return nil }
            if (t["person"] as? NSNumber)?.boolValue == true && !parents.contains(id) { return nil }
            return TagItem(id: id, parent: nil, name: (t["name"] as? String ?? "").trimmingCharacters(in: .whitespaces), count: all,
                           cover: (t["cover"] as? NSNumber)?.intValue)
        }.sorted { $0.count > $1.count }
        return s
    }

    /// Tags that are not people and hold photos. A tag that only groups people (People, People/Van de Putte) is
    /// left out, and so is everything under a top-level tag that is mostly people: those are on the People page.
    /// digiKam's own internal tags (names starting with _) too.
    private static func tags(from raw: [[String: Any]]) -> [TagItem] {
        struct Raw { let id: Int, pid: Int?, name: String, person: Bool, n: Int, all: Int, cover: Int? }
        let list = raw.compactMap { t -> Raw? in
            guard let id = (t["id"] as? NSNumber)?.intValue else { return nil }
            return Raw(id: id, pid: (t["pid"] as? NSNumber)?.intValue, name: (t["name"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                       person: (t["person"] as? NSNumber)?.boolValue ?? false, n: (t["n"] as? NSNumber)?.intValue ?? 0,
                       all: (t["nAll"] as? NSNumber)?.intValue ?? 0, cover: (t["cover"] as? NSNumber)?.intValue)
        }
        var kids: [Int: [Raw]] = [:]
        for t in list { if let p = t.pid { kids[p, default: []].append(t) } }
        // photos tagged with something other than a person, here or below
        var memo: [Int: Bool] = [:]
        func ownPhotos(_ t: Raw) -> Bool {
            if let m = memo[t.id] { return m }
            memo[t.id] = false  // a loop in the tree ends here
            let r = !t.person && (t.n > 0 || (kids[t.id] ?? []).contains(where: ownPhotos))
            memo[t.id] = r
            return r
        }
        // a top-level tag that is mostly people (digiKam's People) is left out whole: a name in it that was never
        // marked as a person (People/Kline/Carole Kline) is still a person, not a theme
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func root(_ t: Raw) -> Int {
            var r = t, steps = 0
            while let p = r.pid, let up = byID[p], steps < 50 { r = up; steps += 1 }
            return r.id
        }
        var total: [Int: Int] = [:], persons: [Int: Int] = [:]
        for t in list { let r = root(t); total[r, default: 0] += 1; if t.person { persons[r, default: 0] += 1 } }
        let peopleRoots = Set(total.keys.filter { persons[$0, default: 0] * 2 > total[$0]! })
        let hidden = Set(list.filter { $0.name.hasPrefix("_") || peopleRoots.contains($0.id) }.map(\.id))
        func underHidden(_ t: Raw) -> Bool {
            var p = t.pid, steps = 0
            while let q = p, steps < 50 { if hidden.contains(q) { return true }; p = list.first { $0.id == q }?.pid; steps += 1 }
            return false
        }
        return list.filter { !$0.person && $0.all > 0 && !hidden.contains($0.id) && ownPhotos($0) && !underHidden($0) }
            .map { TagItem(id: $0.id, parent: $0.pid, name: $0.name, count: $0.all, cover: $0.cover) }
    }

    /// Your own favorites in iopix (not a change to the library's photos).
    /// Several at once (the grid's selection). False when the server refused.
    @discardableResult
    func setFavorites(_ ids: [Int], _ on: Bool) async -> Bool {
        guard !ids.isEmpty else { return true }
        let before = favoriteIDs
        if on { favoriteIDs.formUnion(ids) } else { favoriteIDs.subtract(ids) }
        favorites = favoriteIDs.count
        do {
            _ = try await Self.post("api/favorites", ["ids": ids, "on": on])
            return true
        } catch {
            favoriteIDs = before
            favorites = before.count
            return false
        }
    }

    /// Adds photos to one of your albums, or to a new one when `album` is nil (named `name`). Returns the album.
    func addToAlbum(_ ids: [Int], album: Int?, name: String? = nil) async throws -> Int {
        let id: Int
        if let album {
            _ = try await Self.post("api/ualbums/\(album)", ["ids": ids, "on": true])
            id = album
        } else {
            let r = try await Self.post("api/ualbums", ["name": name ?? "New album", "ids": ids])
            id = (r["id"] as? NSNumber)?.intValue ?? 0
        }
        if let st = try? await IopixClient.shared.json("api/state") {
            albums = (st["albums"] as? [[String: Any]] ?? []).compactMap { a in
                guard let id = (a["id"] as? NSNumber)?.intValue else { return nil }
                return Album(id: id, name: a["name"] as? String ?? "", count: (a["n"] as? NSNumber)?.intValue ?? 0,
                             cover: (a["cover"] as? NSNumber)?.intValue)
            }
        }
        return id
    }

    private static func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var r = IopixClient.shared.request(path, method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await IopixClient.shared.session.data(for: r)
        return try IopixClient.shared.check(data, resp)
    }

    func setFavorite(_ id: Int, _ on: Bool) async {
        if on { favoriteIDs.insert(id) } else { favoriteIDs.remove(id) }
        favorites = favoriteIDs.count
        var r = IopixClient.shared.request("api/favorites", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": [id], "on": on])
        do {
            let (data, resp) = try await IopixClient.shared.session.data(for: r)
            _ = try IopixClient.shared.check(data, resp)  // a refused request (signed out, viewer only) counts as a failure too
        } catch {  // put it back as it was
            if on { favoriteIDs.remove(id) } else { favoriteIDs.insert(id) }
            favorites = favoriteIDs.count
        }
    }

    /// The folders right under `parent` (nil: the top of the library), skipping a lone root folder.
    func children(of parent: Int?) -> [Folder] {
        let ids = Set(folders.map(\.id))
        var list = parent == nil ? folders.filter { $0.parent == nil || !ids.contains($0.parent!) } : folders.filter { $0.parent == parent }
        // one root folder holding everything: its subfolders are shown at the top instead (only when it has some)
        if parent == nil, list.count == 1, let only = list.first, folders.contains(where: { $0.parent == only.id }) {
            list = folders.filter { $0.parent == only.id }
        }
        return list.filter { $0.count > 0 }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The single root folder that the top level stands in for, when there is one (its own photos are shown too).
    var loneRoot: Folder? {
        let ids = Set(folders.map(\.id))
        let tops = folders.filter { $0.parent == nil || !ids.contains($0.parent!) }
        guard tops.count == 1, let only = tops.first, folders.contains(where: { $0.parent == only.id }) else { return nil }
        return only
    }
}

/// Thumbnails and previews, fetched with the sign-in cookies and kept in memory.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.totalCostLimit = 160 << 20 }  // decoded pictures, counted by their real size in memory

    func cached(_ path: String) -> UIImage? { cache.object(forKey: path as NSString) }

    /// After a photo was rotated or cropped: its old pictures are no longer right (the copy on disk the server let us
    /// keep for a day too).
    func forget(_ path: String) {
        cache.removeObject(forKey: path as NSString)
        let client = IopixClient.shared
        client.session.configuration.urlCache?.removeCachedResponse(for: client.request(path))
    }

    /// Signed out: the pictures belonged to that account.
    func removeAll() { cache.removeAllObjects() }

    func image(_ path: String) async -> UIImage? {
        if let hit = cached(path) { return hit }
        guard let (data, resp) = try? await IopixClient.shared.session.data(for: IopixClient.shared.request(path)),
              (resp as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: data) else { return nil }
        let decoded = img.preparingForDisplay() ?? img
        let px = decoded.size.width * decoded.size.height * decoded.scale * decoded.scale
        cache.setObject(decoded, forKey: path as NSString, cost: Int(px) * 4)
        return decoded
    }
}

struct RemoteImage: View {
    let path: String
    var fit = false
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                if fit {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Color.clear.overlay(Image(uiImage: image).resizable().scaledToFill()).clipped()
                }
            } else if !fit {
                #if os(tvOS)
                Color.white.opacity(0.06)
                #else
                Color.secondary.opacity(0.12)
                #endif
            }
        }
        .task(id: path) {
            image = ImageCache.shared.cached(path)
            if image == nil { image = await ImageCache.shared.image(path) }
        }
    }
}

#if os(iOS)
import SwiftUI

/// The marks on a thumbnail, as the web app draws them: a heart for a favorite (bottom left), a face and a pin for
/// named faces and a location (bottom right), and a video's length (top right). The Display setting can hide the
/// heart, face and pin.
struct TileBadges: View {
    let list: PhotoList
    let index: Int
    let favorite: Bool
    @AppStorage("iopix.pref.badges") private var badges = "1"

    var body: some View {
        ZStack {
            if list.isVideo(index) {
                HStack(spacing: 2) {
                    if let d = list.durations[index] { Text(Self.length(d)).font(.caption2.weight(.medium)) }
                    Image(systemName: "play.fill").font(.caption2)
                }
                .padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if badges != "0" {
                if favorite {
                    Image(systemName: "heart.fill").font(.system(size: 11))
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                if list.hasFaces(index) || list.hasLocation(index) {
                    HStack(spacing: 3) {
                        if list.hasFaces(index) { Image(systemName: "face.smiling") }
                        if list.hasLocation(index) { Image(systemName: "mappin") }
                    }
                    .font(.system(size: 11))
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.8), radius: 2)
        .allowsHitTesting(false)
    }

    static func length(_ s: Int) -> String { s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60) }
}
#endif
