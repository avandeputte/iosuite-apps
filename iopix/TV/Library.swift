import SwiftUI
import UIKit

/// A list of photos from iopix, as the web app gets it: ids in order, and which of them are videos.
struct PhotoList: Equatable {
    var ids: [Int] = []
    var videos: Set<Int> = []  // positions in ids
    var times: [Double] = []   // when each was taken (seconds since 1970), when known

    func isVideo(_ i: Int) -> Bool { videos.contains(i) }

    static func load(_ query: [URLQueryItem]) async throws -> PhotoList {
        let j = try await IopixClient.shared.json("api/photos", query: query)
        let ids = (j["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        let vids = Set((j["video"] as? [String: Any] ?? [:]).keys.compactMap(Int.init))
        let times = (j["ts"] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        return PhotoList(ids: ids, videos: vids, times: times)
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
            favorites = (st["favorites"] as? [Any])?.count ?? 0
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The folders right under `parent` (nil: the top of the library), skipping a lone root folder.
    func children(of parent: Int?) -> [Folder] {
        let ids = Set(folders.map(\.id))
        var list = parent == nil ? folders.filter { $0.parent == nil || !ids.contains($0.parent!) } : folders.filter { $0.parent == parent }
        if parent == nil, list.count == 1, let only = list.first { list = folders.filter { $0.parent == only.id } }
        return list.filter { $0.count > 0 }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Thumbnails and previews, fetched with the sign-in cookies and kept in memory.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.totalCostLimit = 300 << 20 }

    func cached(_ path: String) -> UIImage? { cache.object(forKey: path as NSString) }

    func image(_ path: String) async -> UIImage? {
        if let hit = cached(path) { return hit }
        guard let (data, resp) = try? await IopixClient.shared.session.data(for: IopixClient.shared.request(path)),
              (resp as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: data) else { return nil }
        let decoded = img.preparingForDisplay() ?? img
        cache.setObject(decoded, forKey: path as NSString, cost: data.count * 4)
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
