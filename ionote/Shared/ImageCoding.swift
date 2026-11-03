import Foundation
import ImageIO
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum ImageCoding {
    /// The image as PNG (screenshots, photos and clipboard images in any format), or the data unchanged.
    /// Data that is already PNG is returned as is, without decoding and re-encoding it.
    static func png(from data: Data) -> Data {
        if isPNG(data) { return data }
        #if canImport(AppKit)
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
        #else
        return UIImage(data: data)?.pngData() ?? data
        #endif
    }

    static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// A smaller copy of the image, decoded straight at that size (fast, and safe off the main thread).
    static func downsample(_ data: Data, maxPixels: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}

/// PNG files of pictures with readable names, for dragging, sharing, saving and opening in Preview.
/// Each picture is written once, to a folder named after it, and the file is reused after that.
enum ImageExport {
    static func write(_ data: Data, name: String, key: String?) -> URL? {
        let safe = String(name.prefix(80))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = (key ?? UUID().uuidString).replacingOccurrences(of: "/", with: "-")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ionotes-export", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
        let url = dir.appendingPathComponent((safe.isEmpty ? "Image" : safe) + ".png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ImageCoding.png(from: data).write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("ionotes error: \(error)")
            return nil
        }
    }
}
