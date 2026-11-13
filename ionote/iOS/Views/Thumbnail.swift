import ImageIO
import SwiftUI

/// A small, cached preview of a note's image.
struct Thumbnail: View {
    @EnvironmentObject private var store: NotesStore
    let noteID: String
    let version: String?
    var size: CGFloat = 52
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(noteID)-\(version ?? "")") { image = load() }
    }

    private func load() -> UIImage? {
        let key = "\(noteID)-\(version ?? "")" as NSString
        if let cached = Thumbnail.cache.object(forKey: key) { return cached }
        guard let note = store.note(id: noteID), let data = store.imageData(for: note),
              let thumb = Thumbnail.downsample(data, maxPixels: size * 3) else { return nil }
        Thumbnail.cache.setObject(thumb, forKey: key)
        return thumb
    }

    private static let cache = NSCache<NSString, UIImage>()

    static func downsample(_ data: Data, maxPixels: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
