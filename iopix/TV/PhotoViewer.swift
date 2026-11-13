import SwiftUI
import AVKit

struct ViewerStart: Identifiable {
    let id = UUID()
    let list: PhotoList
    let index: Int
    let playing: Bool
    var ambient = false  // started by itself after the remote was left alone: any press ends it
}

/// One photo at a time, full screen. Left and right on the remote move through them, up and down (or a click)
/// show the info panel, holding select adds to favorites, play/pause runs the slideshow, Menu goes back.
struct PhotoViewer: View {
    let start: ViewerStart
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var prefs = TVPrefs.shared
    @State private var order: [Int] = []  // positions in the list, in the order shown (shuffled in a shuffled slideshow)
    @State private var pos = 0
    @State private var playing = false
    @State private var showInfo = true
    @State private var panel = false
    @State private var video: AVPlayer?
    @State private var slideshow: Task<Void, Never>?
    @State private var hideInfo: Task<Void, Never>?
    @State private var zoom: CGFloat = 1
    @State private var zoomAnchor: UnitPoint = .center
    @State private var heart: Bool?  // the big heart shown for a moment after holding select
    @FocusState private var focused: Bool

    private var ids: [Int] { start.list.ids }
    private var index: Int { order.isEmpty ? 0 : order[pos] }
    private var current: Int { ids[index] }
    private var isVideo: Bool { start.list.isVideo(index) }

    var body: some View {
        ZStack {
            Color.black
            if video == nil && !ids.isEmpty {
                RemoteImage(path: "preview/\(current)").blur(radius: 60).opacity(0.55).scaleEffect(1.2).id("bg\(current)")
            }
            if let video {
                VideoPlayer(player: video)
                    .onDisappear { video.pause() }
            } else if !ids.isEmpty {
                RemoteImage(path: "preview/\(current)", fit: true)
                    .scaleEffect(zoom, anchor: zoomAnchor)
                    .id(current)
                    .transition(.opacity)
                if isVideo {
                    Image(systemName: "play.circle.fill").font(.system(size: 140)).foregroundStyle(.white.opacity(0.85))
                }
            }
            if let heart {
                Image(systemName: heart ? "heart.fill" : "heart.slash.fill")
                    .font(.system(size: 220)).foregroundStyle(heart ? .pink : .white).shadow(radius: 20)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            if video == nil, !ids.isEmpty, store.favoriteIDs.contains(current), !panel {
                Image(systemName: "heart.fill").font(.title2).foregroundStyle(.pink).shadow(radius: 6).padding(50)
            }
        }
        .overlay(alignment: .trailing) {
            if panel && video == nil && !ids.isEmpty {
                InfoPanel(photo: current, favorite: store.favoriteIDs.contains(current))
                    .ignoresSafeArea()
                    .transition(.move(edge: .trailing))
            }
        }
        .overlay(alignment: .bottom) {
            if showInfo && video == nil && !panel && !start.ambient {
                HStack {
                    Text("\(pos + 1) of \(ids.count)")
                    Spacer()
                    Text(playing ? "Slideshow · ⏯ to pause" : "◀ ▶ move · ▲ ▼ info · hold select ♥ · ⏯ slideshow\(isVideo ? " · select plays" : "")")
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
            if start.ambient { dismiss(); return }
            guard video == nil else { return }
            switch dir {
            case .left: step(-1)
            case .right: step(1)
            case .up, .down: withAnimation(.easeInOut(duration: 0.3)) { panel.toggle() }
            default: break
            }
        }
        .onPlayPauseCommand { start.ambient ? dismiss() : toggleSlideshow() }
        .onTapGesture {
            if start.ambient { dismiss(); return }
            if isVideo && video == nil { stopSlideshow(); play() } else if video == nil { withAnimation(.easeInOut(duration: 0.3)) { panel.toggle() } }
        }
        .onLongPressGesture(minimumDuration: 0.6) { if !start.ambient { toggleFavorite() } }
        .onExitCommand {
            if let v = video { v.pause(); video = nil; focused = true }
            else if panel { withAnimation { panel = false } }
            else { dismiss() }
        }
        .onAppear {
            AmbientClock.viewerOpen += 1
            order = Array(ids.indices)
            pos = min(max(start.index, 0), max(ids.count - 1, 0))
            focused = true
            flashInfo()
            if start.playing { startSlideshow() }
        }
        .onDisappear {
            AmbientClock.viewerOpen -= 1
            slideshow?.cancel()
            video?.pause()
        }
    }

    // MARK: moving

    private func step(_ by: Int, animated: Bool = true) {
        guard !order.isEmpty else { return }
        withAnimation(animated ? .easeInOut(duration: 0.8) : nil) { pos = (pos + by + order.count) % order.count }
        zoom = 1
        prefetch()
        if !playing { flashInfo() }
    }

    private func prefetch() {
        guard !order.isEmpty else { return }
        let next = ids[order[(pos + 1) % order.count]]
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

    // MARK: slideshow

    private func toggleSlideshow() { playing ? stopSlideshow() : startSlideshow() }

    private func stopSlideshow() {
        playing = false
        slideshow?.cancel()
        withAnimation(.easeOut(duration: 0.5)) { zoom = 1 }
        flashInfo()
    }

    private func startSlideshow() {
        guard !ids.isEmpty else { return }
        if prefs.shuffle || start.ambient {
            let here = index
            order = ids.indices.filter { $0 != here }.shuffled()
            order.insert(here, at: 0)
            pos = 0
        }
        playing = true
        flashInfo()
        prefetch()
        slideshow = Task {
            var skipped = 0
            while !Task.isCancelled {
                if start.list.isVideo(index) && !prefs.playVideos {
                    // passed over; a list of nothing but videos ends the slideshow instead of spinning
                    skipped += 1
                    if skipped >= order.count { stopSlideshow(); return }
                    await Task.yield()
                    step(1, animated: false)
                    continue
                }
                skipped = 0
                if start.list.isVideo(index) {
                    await playToEnd()
                } else {
                    panZoom()
                    try? await Task.sleep(nanoseconds: UInt64(prefs.slideSeconds) * 1_000_000_000)
                }
                if Task.isCancelled { break }
                step(1)
            }
        }
    }

    /// The slow pan and zoom of a slideshow (alternating corners).
    private func panZoom() {
        guard prefs.panAndZoom else { return }
        let anchors: [UnitPoint] = [.topLeading, .bottomTrailing, .topTrailing, .bottomLeading, .center]
        zoomAnchor = anchors[pos % anchors.count]
        zoom = 1
        withAnimation(.linear(duration: Double(prefs.slideSeconds) + 1)) { zoom = 1.12 }
    }

    // MARK: video

    /// The original, or the copy the server makes of a video Apple TV can't play as it is (nil: none to play).
    private func makePlayer() async -> AVPlayer? {
        guard let url = try? await VideoSource.url(for: current) else { return nil }
        return VideoSource.player(url)
    }

    private func play() {
        Task {
            guard let player = await makePlayer() else { return }
            video = player
            player.play()
        }
    }

    /// In a slideshow: the video plays to its end (or fails, or is dismissed, or takes far too long), then the
    /// slideshow goes on.
    private func playToEnd() async {
        guard let player = await makePlayer() else { return }
        video = player
        player.play()
        let item = player.currentItem
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) { break } }
            group.addTask { for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.failedToPlayToEndTimeNotification, object: item) { break } }
            group.addTask { @MainActor in
                // dismissed with Menu, a loading failure, or a 10-minute ceiling
                for _ in 0..<1200 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if self.video !== player || item?.status == .failed || Task.isCancelled { break }
                }
            }
            await group.next()
            group.cancelAll()
        }
        player.pause()
        if video === player { video = nil }
    }

    // MARK: favorites

    private func toggleFavorite() {
        guard !ids.isEmpty else { return }
        let id = current
        let on = !store.favoriteIDs.contains(id)
        withAnimation(.spring(duration: 0.35)) { heart = on }
        Task {
            await store.setFavorite(id, on)
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.easeOut(duration: 0.4)) { heart = nil }
        }
    }
}
