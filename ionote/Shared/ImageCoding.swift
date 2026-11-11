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

    /// The picture's type from its first bytes, for uploading it as it is.
    static func mimeType(of data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if isPNG(data) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
        if b.count >= 12, b[4...7] == [0x66, 0x74, 0x79, 0x70] { return "image/heic" }
        return "application/octet-stream"
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
            NSLog("ionote error: \(error)")
            return nil
        }
    }
}
