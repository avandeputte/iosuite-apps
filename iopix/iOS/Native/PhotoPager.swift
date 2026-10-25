import SwiftUI
import AVKit

/// Where a viewer starts: a list of photos and the one tapped.
struct PagerStart: Identifiable {
    let id = UUID()
    let list: PhotoList
    let index: Int
}

/// Photos full screen, one at a time: swipe between them, pinch or double-tap to zoom, tap to show or hide the
/// buttons. Videos play in place. The heart adds to your favorites, (i) shows what iopix knows about the photo, and
/// the share button hands the original to the iOS share sheet. Editing is in the web app ("Open in iopix").
struct PhotoPager: View {
    let start: PagerStart
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var router: Router
    @State private var index = 0
    @State private var chrome = true
    @State private var info = false
    @State private var sharing: URL?
    @State private var preparing = false
    @State private var problem: String?

    private var ids: [Int] { start.list.ids }
    private var current: Int { ids.isEmpty ? 0 : ids[min(index, ids.count - 1)] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(ids.enumerated()), id: \.offset) { i, id in
                    MediaPage(id: id, knownVideo: start.list.isVideo(i), active: i == index) {
                        withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) { if chrome { topBar } }
        .overlay(alignment: .bottom) { if chrome { bottomBar } }
        .statusBarHidden(!chrome)
        .onAppear { index = min(max(start.index, 0), max(ids.count - 1, 0)) }
        .sheet(isPresented: $info) {
            PhotoInfoSheet(photo: current)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(get: { sharing.map(SharedFile.init) }, set: { if $0 == nil { removeShared() } })) { f in
            ShareSheet(items: [f.url])
        }
        .alert("Couldn't get the photo", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44) }
                .accessibilityLabel("Close")
            Spacer()
            VStack(spacing: 2) {
                if index < start.list.times.count, start.list.times[index] > 0 {
                    Text(Self.day(start.list.times[index])).font(.subheadline.weight(.semibold))
                }
                if ids.count > 1 { Text("\(index + 1) of \(ids.count)").font(.caption).foregroundStyle(.white.opacity(0.7)) }
            }
            Spacer()
            Menu {
                Button { openInWeb() } label: { Label("Open in iopix", systemImage: "safari") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.headline).frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var bottomBar: some View {
        HStack(spacing: 44) {
            Button { Task { await share() } } label: {
                if preparing { ProgressView().tint(.white) } else { Image(systemName: "square.and.arrow.up") }
            }
            .accessibilityLabel("Share")
            .disabled(preparing)
            let fav = store.favoriteIDs.contains(current)
            Button { Task { await store.setFavorite(current, !fav) } } label: {
                Image(systemName: fav ? "heart.fill" : "heart").foregroundStyle(fav ? .pink : .white)
            }
            .accessibilityLabel(fav ? "Remove from favorites" : "Add to favorites")
            Button { info = true } label: { Image(systemName: "info.circle") }
                .accessibilityLabel("Info")
        }
        .font(.title2)
        .foregroundStyle(.white)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    /// The original file, downloaded to a temporary place for the share sheet (removed after).
    private func share() async {
        preparing = true
        defer { preparing = false }
        do {
            let (tmp, resp) = try await IopixClient.shared.session.download(for: IopixClient.shared.request("orig/\(current)"))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let name = (resp as? HTTPURLResponse).flatMap(Self.filename) ?? "iopix-\(current).jpg"
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent(name)
            try FileManager.default.moveItem(at: tmp, to: dst)
            sharing = dst
        } catch {
            problem = error.localizedDescription
        }
    }

    private func removeShared() {
        if let s = sharing { try? FileManager.default.removeItem(at: s.deletingLastPathComponent()) }
        sharing = nil
    }

    private func openInWeb() {
        dismiss()
        router.open("#/photos?p=\(current)")
    }

    private static func filename(_ r: HTTPURLResponse) -> String? {
        guard let cd = r.value(forHTTPHeaderField: "Content-Disposition") else { return nil }
        if let star = cd.range(of: "filename*=UTF-8''") {
            let v = cd[star.upperBound...].split(separator: ";").first.map(String.init) ?? ""
            if let d = v.removingPercentEncoding, !d.isEmpty { return (d as NSString).lastPathComponent }
        }
        if let plain = cd.range(of: "filename=") {
            let v = cd[plain.upperBound...].split(separator: ";").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) } ?? ""
            if !v.isEmpty { return (v as NSString).lastPathComponent }
        }
        return nil
    }

    /// Photo times are the camera's clock, stored as if it were UTC (as the web app shows them).
    static func day(_ ts: Double) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}

private struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// One photo that zooms: pinch, or double-tap to zoom in and out. A single tap is passed on (to show or hide the
/// viewer's buttons).
struct ZoomablePhoto: UIViewRepresentable {
    let id: Int
    var tapped: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        let image = UIImageView()
        image.contentMode = .scaleAspectFit
        image.frame = scroll.bounds
        image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(image)
        context.coordinator.scroll = scroll
        context.coordinator.image = image
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: double)
        scroll.addGestureRecognizer(single)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let c = context.coordinator
        c.tapped = tapped
        guard c.loaded != id else { return }
        c.loaded = id
        scroll.zoomScale = 1
        let thumb = "thumb/\(id)", preview = "preview/\(id)"
        c.image?.image = ImageCache.shared.cached(preview) ?? ImageCache.shared.cached(thumb)
        Task { @MainActor in
            if c.image?.image == nil, let t = await ImageCache.shared.image(thumb), c.loaded == id { c.image?.image = t }
            if let p = await ImageCache.shared.image(preview), c.loaded == id { c.image?.image = p }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scroll: UIScrollView?
        weak var image: UIImageView?
        var loaded: Int?
        var tapped: () -> Void = {}

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }

        @objc func singleTap() { tapped() }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: image)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}

/// One page of the viewer: a photo, or a video. Some lists (Rediscover) don't say which are videos, so the page asks.
struct MediaPage: View {
    let id: Int
    let knownVideo: Bool
    let active: Bool
    var tapped: () -> Void
    @State private var video: Bool?

    var body: some View {
        Group {
            if knownVideo || video == true {
                VideoPage(id: id, active: active)
            } else {
                ZoomablePhoto(id: id, tapped: tapped)
            }
        }
        .task(id: id) {
            guard !knownVideo, video == nil, let d = try? await IopixClient.shared.json("api/photo/\(id)") else { return }
            video = d["playable"] != nil || ((d["duration"] as? NSNumber)?.doubleValue ?? 0) > 0
        }
    }
}

/// A video: its picture with a play button, then the player once tapped. It stops when swiped away.
struct VideoPage: View {
    let id: Int
    let active: Bool
    @State private var player: AVPlayer?
    @State private var preparing: Task<Void, Never>?
    @State private var problem: String?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                RemoteImage(path: "preview/\(id)", fit: true)
                if preparing != nil {
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Getting the video ready…").font(.footnote).foregroundStyle(.white)
                    }
                    .padding(16).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    Button(action: play) {
                        Image(systemName: "play.circle.fill").font(.system(size: 72)).foregroundStyle(.white.opacity(0.9))
                    }
                    .accessibilityLabel("Play video")
                }
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
                        .padding(12).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 120)
                }
            }
        }
        .onChange(of: active) { _, on in if !on { player?.pause(); preparing?.cancel(); preparing = nil } }
        .onDisappear { player?.pause(); player = nil; preparing?.cancel(); preparing = nil }
    }
}

extension VideoPage {
    /// The original when it plays here, otherwise the copy the server makes (it may take a moment the first time).
    private func play() {
        problem = nil
        preparing = Task {
            defer { preparing = nil }
            do {
                let url = try await VideoSource.url(for: id)
                let p = VideoSource.player(url)
                player = p
                p.play()
            } catch is CancellationError {
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// What iopix knows about a photo: its caption (never the AI description), date, place, people, tags, folder,
/// camera and file.
struct PhotoInfoSheet: View {
    let photo: Int
    @State private var info: PhotoInfo?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                if let info {
                    if let t = info.title { Section { Text(t).font(.headline) } }
                    if info.rating > 0 { row("star.fill", String(repeating: "★", count: min(info.rating, 5))) }
                    row("calendar", info.when)
                    row("mappin.and.ellipse", info.place)
                    row("person.2", info.people.isEmpty ? nil : info.people.joined(separator: ", "))
                    row("tag", info.tags.isEmpty ? nil : info.tags.joined(separator: ", "))
                    row("folder", info.folder)
                    row("camera", info.camera)
                    row("camera.aperture", info.settings)
                    row("doc", info.file)
                } else if failed {
                    Text("Couldn't load the details of this photo.").foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: photo) {
            info = await PhotoInfo.load(photo)
            failed = info == nil
        }
    }

    @ViewBuilder private func row(_ icon: String, _ text: String?) -> some View {
        if let text {
            Label { Text(text).textSelection(.enabled) } icon: { Image(systemName: icon).foregroundStyle(.secondary) }
        }
    }
}
