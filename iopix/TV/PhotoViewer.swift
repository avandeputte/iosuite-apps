import SwiftUI
import AVKit

struct ViewerStart: Identifiable {
    let id = UUID()
    let list: PhotoList
    let index: Int
    let playing: Bool
}

/// One photo at a time, full screen. Left and right on the remote move through them, play/pause runs the
/// slideshow, select plays a video, Menu goes back.
struct PhotoViewer: View {
    let start: ViewerStart
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var playing = false
    @State private var showInfo = true
    @State private var video: AVPlayer?
    @State private var slideshow: Task<Void, Never>?
    @State private var hideInfo: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var ids: [Int] { start.list.ids }
    private var current: Int { ids[index] }
    private var isVideo: Bool { start.list.isVideo(index) }

    var body: some View {
        ZStack {
            Color.black
            if let video {
                VideoPlayer(player: video)
                    .onDisappear { video.pause() }
            } else {
                RemoteImage(path: "preview/\(current)", fit: true)
                    .id(current)
                    .transition(.opacity)
                if isVideo {
                    Image(systemName: "play.circle.fill").font(.system(size: 140)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            if showInfo && video == nil {
                    HStack {
                        Text("\(index + 1) of \(ids.count)")
                        Spacer()
                        Text(playing ? "Slideshow · press ⏯ to pause" : "◀ ▶ to move · ⏯ slideshow\(isVideo ? " · select to play" : "")")
                    }
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 60).padding(.vertical, 24)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.bottom, 40)
            }
        }
        .focusable(video == nil)
        .focused($focused)
        .onMoveCommand { dir in
            guard video == nil else { return }
            if dir == .left { step(-1) } else if dir == .right { step(1) }
        }
        .onPlayPauseCommand { toggleSlideshow() }
        .onTapGesture { if isVideo && video == nil { play() } }
        .onExitCommand {
            if let v = video { v.pause(); video = nil; focused = true } else { dismiss() }
        }
        .onAppear {
            index = min(max(start.index, 0), max(ids.count - 1, 0))
            focused = true
            flashInfo()
            if start.playing { toggleSlideshow() }
        }
        .onDisappear { slideshow?.cancel() }
    }

    private func step(_ by: Int) {
        guard !ids.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.4)) { index = (index + by + ids.count) % ids.count }
        prefetch()
        flashInfo()
    }

    private func prefetch() {
        let next = ids[(index + 1) % ids.count]
        Task { _ = await ImageCache.shared.image("preview/\(next)") }
    }

    private func flashInfo() {
        showInfo = true
        hideInfo?.cancel()
        hideInfo = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { withAnimation { showInfo = false } }
        }
    }

    private func toggleSlideshow() {
        if playing {
            playing = false
            slideshow?.cancel()
            flashInfo()
            return
        }
        playing = true
        flashInfo()
        prefetch()
        slideshow = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if Task.isCancelled { break }
                // videos are passed over in a slideshow
                var tries = 0
                repeat { step(1); tries += 1 } while start.list.isVideo(index) && tries < ids.count
            }
        }
    }

    private func play() {
        slideshow?.cancel()
        playing = false
        let url = AppConfig.serverURL.appendingPathComponent("orig/\(current)")
        let cookies = AppConfig.cookies.cookies(for: url) ?? []
        var headers: [String: String] = [:]
        if let id = ServiceToken.clientID, let secret = ServiceToken.clientSecret {
            headers = ["CF-Access-Client-Id": id, "CF-Access-Client-Secret": secret]
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: cookies, "AVURLAssetHTTPHeaderFieldsKey": headers])
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        video = player
        player.play()
    }
}
