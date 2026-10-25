import WidgetKit
import SwiftUI
import AppIntents

/// Photos from iopix on the Mac desktop and in Notification Center: Rediscover, the favorites or an album, a
/// different one every 20 minutes. The iopix app prepares the pictures (the widget cannot sign in to iopix itself).
struct PhotoEntry: TimelineEntry {
    let date: Date
    let id: Int?
    let image: UIImage?
    let title: String
    let year: String
    var note: String?
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PhotoEntry {
        PhotoEntry(date: Date(), id: nil, image: nil, title: "iopix", year: "")
    }

    func snapshot(for configuration: SelectPhotos, in context: Context) async -> PhotoEntry {
        entries(for: configuration).first ?? placeholder(in: context)
    }

    func timeline(for configuration: SelectPhotos, in context: Context) async -> Timeline<PhotoEntry> {
        let list = entries(for: configuration)
        // check again in a while: the app adds the photos of a newly picked album when it next runs
        return Timeline(entries: list, policy: list.count > 1 ? .atEnd : .after(Date().addingTimeInterval(600)))
    }

    private func entries(for configuration: SelectPhotos) -> [PhotoEntry] {
        let source = configuration.source ?? .random
        let photos = WidgetStore.photos(source.id).shuffled()
        let title = source.id == "random" ? "Rediscover" : source.name
        guard !photos.isEmpty else {
            return [PhotoEntry(date: Date(), id: nil, image: nil, title: title, year: "",
                               note: "Open iopix and sign in. Its photos appear here within a few minutes.")]
        }
        // a few entries at a time: each carries its picture, and a widget's schedule must stay small
        return photos.prefix(6).enumerated().map { i, p in
            PhotoEntry(date: Date().addingTimeInterval(Double(i) * 1200), id: p.id, image: WidgetStore.image(p.file), title: title, year: p.year)
        }
    }
}

struct PhotoWidgetView: View {
    let entry: PhotoEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // the photo is part of the widget itself, not its background: macOS removes and tints backgrounds when
            // the desktop is not in front
            if let image = entry.image {
                Color.clear.overlay(Image(uiImage: image).resizable().fullColor().scaledToFill()).clipped()
            } else {
                Color(red: 0.23, green: 0.29, blue: 0.55)
                Image(systemName: "photo.on.rectangle").font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                if let note = entry.note { Text(note).font(.caption).padding(.bottom, 4) }
                Text(entry.title).font(.headline).lineLimit(1)
                if !entry.year.isEmpty { Text(entry.year).font(.caption) }
            }
            .foregroundStyle(.white)
            .shadow(radius: 4)
            .padding(14)
        }
        .containerBackground(for: .widget) { Color.black }
        .widgetURL(entry.id.flatMap { URL(string: "iopix-native://photo/\($0)") } ?? URL(string: "iopix-native://main"))
    }
}

private extension Image {
    /// Keeps the photo in its own colours when macOS shows widgets tinted.
    @ViewBuilder func fullColor() -> some View {
        if #available(iOS 18.0, *) { self.widgetAccentedRenderingMode(.fullColor) } else { self }
    }
}

@main
struct IopixNativeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "iopix.native.photos", intent: SelectPhotos.self, provider: Provider()) { PhotoWidgetView(entry: $0) }
            .configurationDisplayName("iopix")
            .description("Photos from iopix: Rediscover, your favorites or an album. Right-click it › Edit to choose.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
            .contentMarginsDisabled()
            .containerBackgroundRemovable(false)
    }
}
