import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// The Bookmarks widget: 4 (small) or 8 (medium) bookmarks picked in the widget's settings, each opening in the app's
// built-in browser (iostart://open?id=). Until some are picked, the first links of the tree.

struct BookmarksConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Bookmarks"
    static var description = IntentDescription("Pick the bookmarks to show.")

    @Parameter(title: "Bookmarks", size: [.systemSmall: 4, .systemMedium: 8])
    var bookmarks: [BookmarkEntity]?
}

struct BookmarkTile: Hashable {
    var id: Int
    var title: String
    var host: String
    var icon: Data?
}

struct BookmarksEntry: TimelineEntry {
    let date: Date
    let tiles: [BookmarkTile]
    let signedIn: Bool
    let picked: Bool
}

struct BookmarksProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BookmarksEntry {
        let names = ["News", "Weather", "Mail", "Maps", "Recipes", "Bank", "School", "Music"]
        return BookmarksEntry(date: Date(), tiles: names.enumerated().map { BookmarkTile(id: $0.offset, title: $0.element, host: "") }, signedIn: true, picked: true)
    }

    func snapshot(for configuration: BookmarksConfig, in context: Context) async -> BookmarksEntry {
        await entry(configuration, family: context.family, icons: !context.isPreview)
    }

    func timeline(for configuration: BookmarksConfig, in context: Context) async -> Timeline<BookmarksEntry> {
        // the bookmarks change rarely, and the app reloads the widget when they do
        Timeline(entries: [await entry(configuration, family: context.family, icons: true)], policy: .after(Date().addingTimeInterval(6 * 3600)))
    }

    private func entry(_ config: BookmarksConfig, family: WidgetFamily, icons: Bool) async -> BookmarksEntry {
        let n = family == .systemSmall ? 4 : 8
        let all = BookmarkQuery.all()
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let chosen = (config.bookmarks ?? []).compactMap { byID[$0.id] ?? $0 }  // the tree's newest name and address
        let picked = !chosen.isEmpty
        let shown = Array((picked ? chosen : all).prefix(n))
        let account = Account.load()
        var tiles = shown.map { BookmarkTile(id: $0.id, title: $0.title, host: URL(string: $0.url)?.host ?? "") }
        if icons, let account {
            WidgetNetwork.setUp()
            await withTaskGroup(of: (Int, Data?).self) { group in
                for (i, t) in tiles.enumerated() {
                    group.addTask { (i, await WidgetIcons.icon(id: t.id, host: t.host, account: account)) }
                }
                for await (i, data) in group { tiles[i].icon = data }
            }
        }
        return BookmarksEntry(date: Date(), tiles: tiles, signedIn: account != nil, picked: picked)
    }
}

/// The sites' icons as the start page keeps them (`/dav/ext/icon/<id>`), kept a week in the app group, small.
enum WidgetIcons {
    private static var dir: URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Shared.group) else { return nil }
        let d = base.appendingPathComponent("widget-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func icon(id: Int, host: String, account: Account) async -> Data? {
        let key = host.isEmpty ? "id-\(id)" : host.lowercased().replacingOccurrences(of: "/", with: "_")
        let file = dir?.appendingPathComponent(key + ".png")
        if let file, let at = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           at > Date().addingTimeInterval(-7 * 86400) {
            return try? Data(contentsOf: file)  // an empty file: the site has none
        }
        guard let url = API(account: account).iconURL(for: id) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(API.bearer(account), forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await API.session.data(for: req) else { return nil }
        var png = Data()
        if (resp as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: data) {
            // a widget's memory is small: 64 points at most
            let side: CGFloat = 64
            let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
            png = r.pngData { _ in img.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
        }
        if let file { try? png.write(to: file, options: .atomic) }
        return png.isEmpty ? nil : png
    }
}

struct BookmarksWidget: Widget {
    let kind = "net.iothing.iostart.bookmarks"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: BookmarksConfig.self, provider: BookmarksProvider()) { entry in
            BookmarksView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Bookmarks")
        .description("Your favourite bookmarks, one tap away. Press and hold the widget, then Edit Widget, to pick them.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct BookmarksView: View {
    let entry: BookmarksEntry
    /// Nil: the widget's own (set only to draw the widget outside WidgetKit).
    var size: WidgetFamily?
    @Environment(\.widgetFamily) private var widgetFamily
    private var family: WidgetFamily { size ?? widgetFamily }

    var body: some View {
        if !entry.signedIn {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "bookmark").font(.title3).foregroundStyle(.secondary)
                Text("Open ioStart and sign in.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if entry.tiles.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "bookmark").font(.title3).foregroundStyle(.secondary)
                Text("No bookmarks yet.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let columns = family == .systemSmall ? 2 : 4
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { col in
                            let i = row * columns + col
                            if i < entry.tiles.count {
                                Link(destination: DeepLink.bookmark(entry.tiles[i].id).url) { TileView(tile: entry.tiles[i]).foregroundStyle(Color.primary) }
                                    .tint(Color.primary)
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct TileView: View {
    let tile: BookmarkTile

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let data = tile.icon, let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().interpolation(.high).scaledToFit().padding(5)
                        .background(Color.white)
                } else {
                    Text(letters)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(hue: hue, saturation: 0.45, brightness: 0.62))
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(tile.title).font(.caption2).lineLimit(1).frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var letters: String {
        let words = tile.title.split { !$0.isLetter && !$0.isNumber }
        if words.count >= 2, let a = words[0].first, let b = words[1].first { return String([a, b]).uppercased() }
        return String(tile.title.prefix(2)).capitalized
    }

    private var hue: Double {
        let sum = (tile.host.isEmpty ? tile.title : tile.host.replacingOccurrences(of: "www.", with: "")).unicodeScalars
            .reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        return Double(sum) / 360
    }
}
