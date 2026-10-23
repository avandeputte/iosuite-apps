import WidgetKit
import SwiftUI

/// On this day (or Rediscover) on the desktop and in Notification Center. The pictures come from the iopix app,
/// which leaves them in the shared App Group folder.
struct PhotoEntry: TimelineEntry {
    let date: Date
    let id: Int?
    let image: NSImage?
    let title: String
    let year: String
}

struct Provider: TimelineProvider {
    private var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "69M2JRAT8P.net.iothing.iopix")?
            .appendingPathComponent("Widget", isDirectory: true)
    }

    private func photos() -> [(id: Int, file: URL, title: String, year: String)] {
        guard let folder, let data = try? Data(contentsOf: folder.appendingPathComponent("photos.json")),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { p in
            guard let id = p["id"] as? Int, let file = p["file"] as? String else { return nil }
            return (id, folder.appendingPathComponent(file), p["title"] as? String ?? "iopix", p["year"] as? String ?? "")
        }
    }

    func placeholder(in context: Context) -> PhotoEntry {
        PhotoEntry(date: Date(), id: nil, image: nil, title: "On this day", year: "")
    }

    func getSnapshot(in context: Context, completion: @escaping (PhotoEntry) -> Void) {
        let p = photos().first
        completion(PhotoEntry(date: Date(), id: p?.id, image: p.flatMap { NSImage(contentsOf: $0.file) }, title: p?.title ?? "On this day", year: p?.year ?? ""))
    }

    /// A different photo every half hour.
    func getTimeline(in context: Context, completion: @escaping (Timeline<PhotoEntry>) -> Void) {
        let list = photos()
        guard !list.isEmpty else {
            completion(Timeline(entries: [placeholder(in: context)], policy: .after(Date().addingTimeInterval(1800))))
            return
        }
        let entries = list.enumerated().map { i, p in
            PhotoEntry(date: Date().addingTimeInterval(Double(i) * 1800), id: p.id, image: NSImage(contentsOf: p.file), title: p.title, year: p.year)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct PhotoWidgetView: View {
    let entry: PhotoEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer()
            Text(entry.title).font(.headline)
            if !entry.year.isEmpty { Text(entry.year).font(.caption) }
        }
        .foregroundStyle(.white)
        .shadow(radius: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .containerBackground(for: .widget) {
            ZStack {
                Color(red: 0.23, green: 0.29, blue: 0.55)
                if let image = entry.image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
                }
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            }
        }
        .widgetURL(entry.id.flatMap { URL(string: "iopix://photo/\($0)") } ?? URL(string: "iopix://today"))
    }
}

@main
struct IopixWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "iopix.onthisday", provider: Provider()) { PhotoWidgetView(entry: $0) }
            .configurationDisplayName("iopix")
            .description("On this day in your iopix library, or photos to rediscover.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
