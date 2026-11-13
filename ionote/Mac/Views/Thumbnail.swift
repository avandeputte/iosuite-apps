import os
import ImageIO
import SwiftUI

/// A small, cached preview of an inbox image file or a note's image.
struct Thumbnail: View {
    enum Source: Hashable {
        case file(String)
        case note(id: String, version: String?)
    }

    @EnvironmentObject private var store: NotesStore
    let source: Source
    var size: CGFloat = 44
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: source) { await load() }
    }

    /// Cached thumbnails come back at once; others are decoded off the main thread, so scrolling
    /// and selecting stay smooth.
    private func load() async {
        let key = cacheKey
        if let cached = Thumbnail.cache.object(forKey: key) {
            image = cached
            return
        }
        image = nil
        let pixels = size * 2
        let cg: CGImage?
        switch source {
        case .file(let path):
            cg = await Task.detached(priority: .utility) {
                FileManager.default.contents(atPath: path).flatMap { ImageCoding.downsample($0, maxPixels: pixels) }
            }.value
        case .note(let id, _):
            guard let data = store.note(id: id).flatMap({ store.imageData(for: $0) }) else { return }
            cg = await Task.detached(priority: .utility) { ImageCoding.downsample(data, maxPixels: pixels) }.value
        }
        guard !Task.isCancelled, let cg else { return }
        let thumb = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        Thumbnail.cache.setObject(thumb, forKey: key)
        image = thumb
    }

    /// A note's picture doesn't change when its text is edited, so the thumbnail is kept per note.
    private var cacheKey: NSString {
        switch source {
        case .file(let path): return "file:\(path)" as NSString
        case .note(let id, let version): return "note:\(id)@\(Int(size))/\(version ?? "")" as NSString
        }
    }

    private static let cache = NSCache<NSString, NSImage>()

    static func downsample(_ data: Data, maxPixels: CGFloat) -> NSImage? {
        guard let cg = ImageCoding.downsample(data, maxPixels: maxPixels) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// The picture shown in a note or Inbox item: a screen-sized copy, decoded off the main thread
/// and kept in memory, so going back to a note shows it at once.
enum ImagePreview {
    static let maxPixels: CGFloat = 1600
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        return cache
    }()

    static func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    @MainActor
    static func load(_ key: String, data: @escaping @Sendable () -> Data?) async -> NSImage? {
        if let hit = cached(key) { return hit }
        let start = Date()
        let cg = await Task.detached(priority: .userInitiated) {
            data().flatMap { ImageCoding.downsample($0, maxPixels: maxPixels) }
        }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key as NSString)
        Log.app.info("preview \(key, privacy: .public) decoded in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        return image
    }
}
