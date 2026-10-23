import TVServices

/// The row of photos on the Apple TV home screen when iopix is in the top row: On this day, or Rediscover when
/// nothing was taken on this date. The extension signs in with the app's cookies (shared App Group) and keeps
/// the pictures in the shared folder, since the home screen cannot sign in to iopix itself.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        Task {
            completionHandler(await Self.content())
        }
    }

    private static func content() async -> TVTopShelfContent? {
        let client = IopixClient.shared
        guard let account = try? await client.account(), account.signedIn else { return nil }
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        var title = "On this day"
        var ids = ((try? await client.json("api/photos", query: [URLQueryItem(name: "md", value: String(format: "%02d-%02d", c.month ?? 1, c.day ?? 1)),
                                                               URLQueryItem(name: "type", value: "photo")]))?["id"] as? [Any] ?? [])
            .compactMap { ($0 as? NSNumber)?.intValue }
        if ids.count < 4 {
            title = "Rediscover"
            ids = ((try? await client.json("api/random", query: [URLQueryItem(name: "n", value: "16")]))?["id"] as? [Any] ?? [])
                .compactMap { ($0 as? NSNumber)?.intValue }
        }
        let folder = AppConfig.dataFolder.appendingPathComponent("TopShelf", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var items: [TVTopShelfSectionedItem] = []
        for id in ids.shuffled().prefix(16) {
            guard let (data, resp) = try? await client.session.data(for: client.request("preview/\(id)")),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let file = folder.appendingPathComponent("\(id).jpg")
            guard (try? data.write(to: file)) != nil else { continue }
            let item = TVTopShelfSectionedItem(identifier: String(id))
            item.imageShape = .hdtv
            item.setImageURL(file, for: .screenScale1x)
            item.setImageURL(file, for: .screenScale2x)
            if let open = URL(string: "iopix://photo/\(id)") {
                item.displayAction = TVTopShelfAction(url: open)
                item.playAction = TVTopShelfAction(url: open)
            }
            items.append(item)
        }
        guard !items.isEmpty else { return nil }
        let section = TVTopShelfItemCollection(items: items)
        section.title = title
        return TVTopShelfSectionedContent(sections: [section])
    }
}
