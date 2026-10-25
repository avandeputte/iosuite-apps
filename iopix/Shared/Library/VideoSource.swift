import Foundation
import AVFoundation

/// What to play for a video. iopix 1.78 and later say whether the original plays on Apple devices as it is; for
/// one that doesn't (an AVI, an unusual codec) the server makes an H.264 copy, which can take a moment the first
/// time. Older servers: the original.
enum VideoSource {
    enum Problem: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let why): return "This video can't be played here. \(why)" }
        }
    }

    static func url(for id: Int) async throws -> URL {
        let client = IopixClient.shared
        let orig = AppConfig.serverURL.appendingPathComponent("orig/\(id)")
        let d = try? await client.json("api/photo/\(id)")
        try Task.checkCancellation()  // swiped away while asking: no player for a page that has gone
        guard let d, let playable = d["playable"] as? Bool, !playable else { return orig }
        let mp4 = AppConfig.serverURL.appendingPathComponent("video/\(id).mp4")
        for _ in 0..<240 {  // up to about 20 minutes for a long video
            try Task.checkCancellation()
            var r = client.request("video/\(id).mp4")
            r.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            let (data, resp) = try await client.session.data(for: r)
            let http = resp as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200, 206:
                return mp4
            case 503:
                let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
                try await Task.sleep(nanoseconds: UInt64(max(1, min(wait, 30)) * 1_000_000_000))
            case 422:
                let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                throw Problem.failed(j?["detail"] as? String ?? "")
            default:
                return orig
            }
        }
        throw Problem.failed("Making a copy that plays took too long.")
    }

    /// A player for the video at `url`, with the sign-in.
    static func player(_ url: URL) -> AVPlayer {
        let cookies = AppConfig.cookies.cookies(for: url) ?? []
        return AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: cookies])))
    }
}
