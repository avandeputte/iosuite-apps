import Foundation
import AVFoundation

/// What to play for a video. ioPix says whether the original plays on Apple devices as it is. The original is served at
/// the home address only (the address for apps serves the pictures and the copies that play, /video/), so away from
/// home, or for one that doesn't play as it is (an AVI, an unusual codec), the server's H.264 copy is played, which can
/// take a moment to make the first time.
enum VideoSource {
    enum Problem: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let why): return "This video can't be played here. \(why)" }
        }
    }

    static func url(for id: Int) async throws -> URL {
        let client = IopixClient.shared
        let d = try? await client.json("api/photo/\(id)")
        try Task.checkCancellation()  // swiped away while asking: no player for a page that has gone
        let playable = d?["playable"] as? Bool ?? true
        if playable, let home = AppConfig.homeURL, await HomeServer.shared.check() {
            return home.appendingPathComponent("orig/\(id)")
        }
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
                throw Problem.failed("The server answered \(http?.statusCode ?? 0).")
            }
        }
        throw Problem.failed("Making a copy that plays took too long.")
    }

    /// A player for the video at `url`, with this device's app password (Authorization: Bearer).
    static func player(_ url: URL) -> AVPlayer {
        AVPlayer(playerItem: AVPlayerItem(asset: asset(url)))
    }

    static func asset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": IopixClient.shared.authHeaders])
    }
}
