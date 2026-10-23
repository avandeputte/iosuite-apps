import SwiftUI
import Photos

/// The new photos found in the library: tap to pick, then send the picked ones (or all) or ignore them.
struct ReviewView: View {
    @EnvironmentObject private var queue: UploadQueue
    @State private var picked: Set<UUID> = []

    var body: some View {
        let items = queue.reviewing
        VStack(spacing: 0) {
            if items.isEmpty {
                ContentUnavailableView("No new photos", systemImage: "photo.on.rectangle",
                                       description: Text("New photos and videos in your library show up here, for you to send to iopix or ignore."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 4)], spacing: 4) {
                        ForEach(items) { item in cell(item) }
                    }
                    .padding(4)
                }
                Divider()
                HStack {
                    Button(picked.count == items.count ? "Pick none" : "Pick all") {
                        picked = picked.count == items.count ? [] : Set(items.map(\.id))
                    }
                    Spacer()
                    Button(picked.isEmpty ? "Ignore all" : "Ignore \(picked.count)") {
                        queue.ignore(picked.isEmpty ? Set(items.map(\.id)) : picked)
                        picked = []
                    }
                    Button(picked.isEmpty ? "Send all" : "Send \(picked.count)") {
                        queue.send(picked.isEmpty ? Set(items.map(\.id)) : picked)
                        picked = []
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(12)
            }
        }
        .navigationTitle(items.isEmpty ? "New photos" : "\(items.count) new photo\(items.count == 1 ? "" : "s")")
        .onChange(of: items.map(\.id)) { _, ids in picked.formIntersection(ids) }
    }

    private func cell(_ item: UploadItem) -> some View {
        let on = picked.contains(item.id)
        return AssetThumbnail(source: item.source)
            .overlay(alignment: .topTrailing) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.85), on ? Color.accentColor : Color.black.opacity(0.25))
                    .padding(6)
            }
            .overlay { if on { Rectangle().strokeBorder(Color.accentColor, lineWidth: 3) } }
            .contentShape(Rectangle())
            .onTapGesture { if on { picked.remove(item.id) } else { picked.insert(item.id) } }
            .help(item.name)
            .accessibilityLabel(item.name)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A square preview of a library photo (videos get a small mark).
struct AssetThumbnail: View {
    let source: UploadItem.Source
    @State private var image: Image?
    @State private var video = false

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay { if let image { image.resizable().scaledToFill() } }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if video { Image(systemName: "video.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(6) }
            }
            .task(id: source) { await load() }
    }

    private func load() async {
        guard case .asset(let id) = source,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
        video = asset.mediaType == .video
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat  // one answer only
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        image = await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 320, height: 320), contentMode: .aspectFill, options: opts) { img, _ in
                #if os(iOS)
                cont.resume(returning: img.map { Image(uiImage: $0) })
                #else
                cont.resume(returning: img.map { Image(nsImage: $0) })
                #endif
            }
        }
    }
}
