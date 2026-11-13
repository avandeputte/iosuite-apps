import Foundation

/// What the share extension hands the app: each share is a folder in the App Group container (ShareInbox/<id>/) with
/// item.json and the shared files beside it. The app turns them into notes when it next comes to the front, and keeps
/// a folder until its files are on the server too (sharing works offline).
enum ShareInbox {
    static let appGroup = "group.net.iothing.ionotes"

    struct Item: Codable {
        var text: String = ""
        var url: String?
        var files: [String] = []
        var createdAt: Double = Date().timeIntervalSince1970
        /// The note made from it, once there is one (only the files are left to send).
        var noteID: String?
    }

    static var root: URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let dir = base.appendingPathComponent("ShareInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A new share's folder (the extension writes the files into it, then `write(_:to:)`).
    static func newFolder() -> URL? {
        guard let root else { return nil }
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(_ item: Item, to dir: URL) throws {
        try JSONEncoder().encode(item).write(to: dir.appendingPathComponent("item.json"), options: .atomic)
    }

    /// The shares waiting, oldest first.
    static func pending() -> [(dir: URL, item: Item)] {
        guard let root, let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("item.json")),
                  let item = try? JSONDecoder().decode(Item.self, from: data) else {
                // a share still being written, or a broken one a day old
                let made = (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
                if Date().timeIntervalSince(made) > 86400 { try? FileManager.default.removeItem(at: dir) }
                return nil
            }
            return (dir, item)
        }
        .sorted { $0.item.createdAt < $1.item.createdAt }
    }

    static func done(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}
