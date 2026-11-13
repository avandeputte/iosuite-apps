import AppIntents
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What the iopix widget shows (Mac, from the iPhone/iPad app running there): random photos (Rediscover), the
/// favorites, or one album. Shared by the widget, where it is picked (right-click the widget › Edit "iopix"), and
/// the app, which prepares the photos for it in the App Group.
struct WidgetSourceEntity: AppEntity {
    let id: String  // "random", "favorites", "album-<id>"
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Photos"
    static var defaultQuery = WidgetSourceQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static let random = WidgetSourceEntity(id: "random", name: "Rediscover (random)")
    static let favorites = WidgetSourceEntity(id: "favorites", name: "Favorites")
}

struct WidgetSourceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetSourceEntity] {
        WidgetStore.sources().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [WidgetSourceEntity] { WidgetStore.sources() }
    func defaultResult() async -> WidgetSourceEntity? { .random }
}

struct SelectPhotos: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Photos to show"
    static var description = IntentDescription("Rediscover (random photos), your favorites, or one of your ioPix albums.")

    @Parameter(title: "Show")
    var source: WidgetSourceEntity?

    init() {}
}

/// The widget's photos, which the app keeps in the shared App Group folder (the widget cannot sign in to iopix).
enum WidgetStore {
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.net.iothing.iopix")?
            .appendingPathComponent("Widget", isDirectory: true)
    }

    /// Rediscover and Favorites, then the albums the app listed.
    static func sources() -> [WidgetSourceEntity] {
        var out: [WidgetSourceEntity] = [.random, .favorites]
        if let folder, let data = try? Data(contentsOf: folder.appendingPathComponent("albums.json")),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            out += list.compactMap { a in
                guard let id = a["id"] as? Int, let name = a["name"] as? String else { return nil }
                return WidgetSourceEntity(id: "album-\(id)", name: name)
            }
        }
        return out
    }

    struct Photo {
        let id: Int
        let file: URL
        let year: String
    }

    #if canImport(UIKit)
    /// The picture read into memory now: the app replaces these files when it refreshes.
    static func image(_ file: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return UIImage(data: data)
    }
    #endif

    static func photos(_ key: String) -> [Photo] {
        guard let dir = folder?.appendingPathComponent(key, isDirectory: true),
              let data = try? Data(contentsOf: dir.appendingPathComponent("photos.json")),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { p in
            guard let id = p["id"] as? Int, let file = p["file"] as? String else { return nil }
            return Photo(id: id, file: dir.appendingPathComponent(file), year: p["year"] as? String ?? "")
        }
    }
}
