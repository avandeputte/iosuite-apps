import SwiftUI
import UIKit

/// A list of photos from iopix, as the web app gets it: ids in order, and which of them are videos.
struct PhotoList: Equatable {
    var ids: [Int] = []
    var videos: Set<Int> = []  // positions in ids
    var times: [Double] = []   // when each was taken (seconds since 1970), when known

    func isVideo(_ i: Int) -> Bool { videos.contains(i) }

    static func load(_ query: [URLQueryItem]) async throws -> PhotoList {
        PhotoList(json: try await IopixClient.shared.json("api/photos", query: query))
    }

    /// From any answer that lists photos the way api/photos does (api/random too).
    init(json j: [String: Any]) {
        ids = (j["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        videos = Set((j["video"] as? [String: Any] ?? [:]).keys.compactMap(Int.init))
        times = (j["ts"] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
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
}

struct Place: Identifiable, Hashable {
    let name: String
    let region: String?
    let country: String?
    let count: Int
    let cover: Int?
    var id: String { [name, region ?? "", country ?? ""].joined(separator: "|") }
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
    @Published var problem: String?

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
                return Person(id: id, name: t["name"] as? String ?? "", count: n, face: (t["face"] as? NSNumber)?.intValue)
            }.sorted { $0.count > $1.count }
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
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Your own favorites in iopix (not a change to the library's photos).
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
                Color.white.opacity(0.06)
            }
        }
        .task(id: path) {
            image = ImageCache.shared.cached(path)
            if image == nil { image = await ImageCache.shared.image(path) }
        }
    }
}
