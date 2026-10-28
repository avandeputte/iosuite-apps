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
    @State private var ids: [Int]
    @State private var editing = false
    @State private var faces = false
    @State private var reloadKey = 0
    @ObservedObject private var rights = EditRights.shared
    @State private var chrome = true
    /// The info pane beside the photo (wide screens) stays open from one photo, and one viewing, to the next.
    @AppStorage("iopix.viewer.infoPane") private var pane = false
    @State private var sheet = false
    /// Face boxes over the photo, as the web app's F key shows them; kept from one photo to the next.
    @AppStorage("iopix.viewer.faces") private var showFaces = false
    private var info: Bool { sidePane ? pane : sheet }
    /// On a wide screen editing happens in the pane beside the photo, as in the web app; on iPhone it is a sheet.
    private var editInPane: Bool { editing && sidePane }
    @Environment(\.horizontalSizeClass) private var width
    /// On a wide screen (iPad) the details sit in a pane beside the photo, as on the web; on a phone in a sheet.
    private var sidePane: Bool { width == .regular }
    @State private var sharing: URL?
    @State private var preparing = false
    @State private var problem: String?

    init(start: PagerStart) {
        self.start = start
        _index = State(initialValue: min(max(start.index, 0), max(start.list.ids.count - 1, 0)))
        _ids = State(initialValue: start.list.ids)
    }

    private var current: Int { ids.isEmpty ? 0 : ids[min(index, ids.count - 1)] }

    /// Whether page `i` is a video, by the list it came from (a removed photo shifts the positions after it).
    private func isVideo(_ i: Int) -> Bool {
        guard i < ids.count, let original = start.list.ids.firstIndex(of: ids[i]) else { return false }
        return start.list.isVideo(original)
    }

    /// The date of page `i` as far as it is known ("May 1992", "1992", "Date unknown" for an approximate one).
    private func dateText(_ i: Int) -> String? {
        guard i < ids.count, let original = start.list.ids.firstIndex(of: ids[i]) else { return nil }
        return start.list.dateText(original)
    }

    private func takenAt(_ i: Int) -> Double? {
        guard i < ids.count, let original = start.list.ids.firstIndex(of: ids[i]), original < start.list.times.count,
              start.list.times[original] > 0 else { return nil }
        return start.list.times[original]
    }

    /// What an edit in the sheet or the pane changed: reload, or leave a trashed photo out.
    private func handle(_ outcome: EditOutcome) {
        switch outcome {
        case .changed: reloadKey += 1
        case .pictureChanged:
            ImageCache.shared.forget("thumb/\(current)"); ImageCache.shared.forget("preview/\(current)")
            reloadKey += 1
        case .removed:
            let gone = current
            if ids.count <= 1 { dismiss() } else { ids.removeAll { $0 == gone }; index = min(index, ids.count - 1); reloadKey += 1 }
            NotificationCenter.default.post(name: .iopixPhotosChanged, object: nil, userInfo: ["removed": [gone]])
        case .added:
            NotificationCenter.default.post(name: .iopixPhotosChanged, object: nil)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black.ignoresSafeArea()
                // pages are made as they come into view, so a list of the whole library swipes as well as a short one
                PageView(count: ids.count, index: $index) { i in
                    AnyView(MediaPage(id: ids[i], knownVideo: isVideo(i), active: true, showFaces: showFaces) {
                        withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
                    }
                    .ignoresSafeArea())
                }
                .id("\(reloadKey)-\(showFaces)")
                .ignoresSafeArea()
            }
            .overlay(alignment: .top) { if chrome { topBar } }
            if editInPane {
                PhotoEditSheet(photo: current, onOutcome: handle, inPane: { editing = false })
                    .id(current)  // another photo: its own details, not the last one's draft
                    .frame(width: 360)
                    .transition(.move(edge: .trailing))
            } else if info && sidePane {
                PhotoInfoPane(photo: current, edit: rights.canWrite ? { editing = true } : nil) { route in
                    // one photo (the best frame of this burst): shown here, in place; it joins the list if it is not in it
                    if let p = route.hasPrefix("#/photos?p=") ? Int(route.dropFirst("#/photos?p=".count)) : nil {
                        if let i = ids.firstIndex(of: p) { index = i } else { ids.insert(p, at: index + 1); index += 1 }
                        return
                    }
                    // a date, person, tag or place in the panel: its photos, as the web app's panel does
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { router.open(route) }
                }
                    .frame(width: 360)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: info)
        .animation(.easeInOut(duration: 0.25), value: editInPane)
        .statusBarHidden(!chrome)
        .sheet(isPresented: Binding(get: { sheet && !sidePane }, set: { sheet = $0 })) {
            PhotoInfoSheet(photo: current)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(get: { editing && !sidePane }, set: { editing = $0 })) {
            PhotoEditSheet(photo: current, onOutcome: handle)
        }
        .fullScreenCover(isPresented: $faces) {
            EditFacesView(photo: current) { reloadKey += 1 }
        }
        .hidesMacToolbar()
        .task { await rights.refresh() }
        .sheet(item: Binding(get: { sharing.map(SharedFile.init) }, set: { if $0 == nil { removeShared() } })) { f in
            ShareSheet(items: [f.url])
        }
        .alert("Couldn't get the photo", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: { ViewerIcon(symbol: "xmark") }
                .accessibilityLabel("Close")
            VStack(alignment: .leading, spacing: 2) {
                if let t = dateText(index) {
                    Text(t).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }
                if ids.count > 1 { Text("\(index + 1) of \(ids.count)").font(.caption).foregroundStyle(.white.opacity(0.7)) }
            }
            .shadow(color: .black.opacity(0.6), radius: 3)
            Spacer(minLength: 4)
            // share, favorite, info and more at the top right, all drawn the same way on iPhone, iPad and Mac
            Button { Task { await share() } } label: { ViewerIcon(symbol: "square.and.arrow.up", busy: preparing) }
                .accessibilityLabel("Share")
                .disabled(preparing)
            let fav = store.favoriteIDs.contains(current)
            Button { Task { await store.setFavorite(current, !fav) } } label: {
                ViewerIcon(symbol: fav ? "heart.fill" : "heart", tint: fav ? .pink : .white)
            }
            .accessibilityLabel(fav ? "Remove from favorites" : "Add to favorites")
            if !isVideo(index) {
                Button { showFaces.toggle() } label: { ViewerIcon(symbol: showFaces ? "person.crop.square.fill" : "person.crop.square") }
                    .accessibilityLabel(showFaces ? "Hide faces" : "Show faces")
            }
            Button {
                if sidePane { if editing { editing = false; pane = true } else { pane.toggle() } } else { sheet.toggle() }
            } label: { ViewerIcon(symbol: info ? "info.circle.fill" : "info.circle") }
                .accessibilityLabel("Info")
            Menu {
                if rights.canWrite {
                    Button { editing = true } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                    Button { faces = true } label: { Label("Edit faces…", systemImage: "person.crop.rectangle") }
                }
                Button { openInWeb() } label: { Label("Open in iopix", systemImage: "safari") }
            } label: {
                ViewerIcon(symbol: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .accessibilityLabel("More")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
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

    static func filename(_ r: HTTPURLResponse) -> String? {
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
    var faces: FaceBoxes?
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
        let layer = FaceLayer(frame: image.bounds)
        layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        image.addSubview(layer)  // inside the picture: the boxes zoom and pan with it
        context.coordinator.faceLayer = layer
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
        c.faceLayer?.boxes = faces
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
        weak var faceLayer: FaceLayer?
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
    var showFaces = false
    var tapped: () -> Void
    @State private var video: Bool?
    @State private var boxes: FaceBoxes?

    var body: some View {
        Group {
            if knownVideo || video == true {
                VideoPage(id: id, active: active)
            } else {
                ZoomablePhoto(id: id, faces: showFaces ? boxes : nil, tapped: tapped)
            }
        }
        .task(id: showFaces ? id : -id) {
            guard showFaces, boxes == nil, let d = await PhotoDetail.load(id), !d.video else { return }
            boxes = FaceBoxes(width: d.w, height: d.h, faces: d.faces.filter { $0.rect.count == 4 })
        }
        .task(id: id) {
            guard !knownVideo, video == nil, let d = try? await IopixClient.shared.json("api/photo/\(id)") else { return }
            video = (d["video"] as? NSNumber)?.boolValue == true || d["playable"] != nil || ((d["duration"] as? NSNumber)?.doubleValue ?? 0) > 0
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
                try Task.checkCancellation()
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

/// The details beside the photo on a wide screen, like the web app's info panel.
struct PhotoInfoPane: View {
    let photo: Int
    /// Set for accounts that can change photos: an Edit button beside the heading turns the pane into the editor.
    var edit: (() -> Void)? = nil
    var open: (String) -> Void = { _ in }

    var body: some View {
        PhotoInfoFull(photo: photo, open: open)
            // the heading stays put above the details as they scroll, on its own strip
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Text("Info").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    if let edit {
                        Button(action: edit) { Label("Edit", systemImage: "slider.horizontal.3") }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
                .background(.regularMaterial)
            }
            .background(.regularMaterial)
            .ignoresSafeArea(edges: .bottom)
    }
}

struct PhotoInfoSheet: View {
    let photo: Int

    var body: some View {
        NavigationStack {
            PhotoInfoList(photo: photo)
                .navigationTitle("Info")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// What iopix knows about a photo: its caption (never the AI description), date, place, people, tags, folder,
/// camera and file.
struct PhotoInfoList: View {
    let photo: Int
    @State private var info: PhotoInfo?
    @State private var failed = false

    var body: some View {
        Group {
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

/// Swiping between pages, made one at a time as they come into view (UIPageViewController).
struct PageView: UIViewControllerRepresentable {
    let count: Int
    @Binding var index: Int
    let page: (Int) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 16])
        pvc.view.backgroundColor = .clear
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        if count > 0 { pvc.setViewControllers([context.coordinator.controller(min(index, count - 1))], direction: .forward, animated: false) }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        let shown = (pvc.viewControllers?.first as? Page)?.index
        if count > 0, shown != index, index < count {
            pvc.setViewControllers([context.coordinator.controller(index)], direction: (shown ?? 0) < index ? .forward : .reverse, animated: false)
        }
    }

    final class Page: UIHostingController<AnyView> {
        var index = 0
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageView
        init(_ p: PageView) { parent = p }

        func controller(_ i: Int) -> Page {
            let c = Page(rootView: parent.page(i))
            c.index = i
            c.view.backgroundColor = .clear
            return c
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? Page)?.index, i > 0 else { return nil }
            return controller(i - 1)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? Page)?.index, i + 1 < parent.count else { return nil }
            return controller(i + 1)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            if completed, let i = (pvc.viewControllers?.first as? Page)?.index { parent.index = i }
        }
    }
}

extension Notification.Name {
    /// Photos were trashed, restored or added from the viewer or an editing sheet; lists reload. userInfo["removed"]: ids gone.
    static let iopixPhotosChanged = Notification.Name("iopixPhotosChanged")
}

/// A round button of the photo viewer: the same on iPhone, iPad and Mac (where buttons and menus otherwise get
/// different frames), and readable on a bright photo.
struct ViewerIcon: View {
    let symbol: String
    var tint: Color = .white
    var busy = false

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.35))
            if busy { ProgressView().tint(.white) } else { Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint) }
        }
        .frame(width: 38, height: 38)
        .contentShape(Circle())
    }
}

extension View {
    /// On the Mac, the window's own toolbar (the screen underneath's buttons: photo size, send photos) stays above
    /// a full-screen cover; while the viewer is up it is hidden, so only the viewer's buttons show.
    func hidesMacToolbar() -> some View {
        #if targetEnvironment(macCatalyst)
        return onAppear { MacToolbar.hide(true) }.onDisappear { MacToolbar.hide(false) }
        #else
        return self
        #endif
    }
}

#if targetEnvironment(macCatalyst)
@MainActor
private enum MacToolbar {
    static var depth = 0

    static func hide(_ on: Bool) {
        depth = max(0, depth + (on ? 1 : -1))
        let show = depth == 0
        // SwiftUI puts the screens' toolbar items in the window's AppKit toolbar, out of UIKit's reach
        MacMenuBar.shared.bar?.showToolbars(show)
        // and may put it back as the screen underneath updates: once more after it settles
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if (depth == 0) == show { MacMenuBar.shared.bar?.showToolbars(show) }
        }
    }
}
#endif

/// The faces of one photo, in its own (upright) pixels.
struct FaceBoxes {
    let width: Int
    let height: Int
    let faces: [PhotoDetail.Face]
}

/// Face boxes drawn over the picture where it sits (aspect fit), each with its name below: named in white,
/// suggestions in yellow, unknown faces dashed.
final class FaceLayer: UIView {
    var boxes: FaceBoxes? { didSet { rebuild() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        for f in boxes?.faces ?? [] {
            let box = UIView()
            box.layer.borderWidth = 2
            box.layer.cornerRadius = 4
            let color: UIColor = f.kind == .suggested ? .systemYellow : .white
            box.layer.borderColor = color.cgColor
            if f.kind == .unknown {
                let dash = CAShapeLayer()
                dash.strokeColor = UIColor.white.cgColor
                dash.fillColor = nil
                dash.lineDashPattern = [5, 4]
                dash.lineWidth = 2
                box.layer.borderWidth = 0
                box.layer.addSublayer(dash)
            }
            box.layer.shadowColor = UIColor.black.cgColor
            box.layer.shadowOpacity = 0.5
            box.layer.shadowRadius = 2
            box.layer.shadowOffset = .zero
            addSubview(box)
            let label = PaddedLabel()
            label.text = f.kind == .unknown ? "Unknown" : (f.kind == .suggested ? "\(f.name ?? "")?" : f.name)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = color
            label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            label.layer.cornerRadius = 4
            label.clipsToBounds = true
            label.isHidden = label.text?.isEmpty ?? true
            addSubview(label)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let b = boxes, b.width > 0, b.height > 0 else { return }
        // where an aspect-fit picture of the photo's shape sits in these bounds
        let scale = min(bounds.width / CGFloat(b.width), bounds.height / CGFloat(b.height))
        let ox = (bounds.width - CGFloat(b.width) * scale) / 2, oy = (bounds.height - CGFloat(b.height) * scale) / 2
        let views = subviews
        for (k, f) in b.faces.enumerated() where k * 2 + 1 < views.count {
            let r = CGRect(x: ox + CGFloat(f.rect[0]) * scale, y: oy + CGFloat(f.rect[1]) * scale,
                           width: CGFloat(f.rect[2]) * scale, height: CGFloat(f.rect[3]) * scale)
            let box = views[k * 2], label = views[k * 2 + 1]
            box.frame = r
            if let dash = box.layer.sublayers?.first as? CAShapeLayer {
                dash.path = UIBezierPath(roundedRect: box.bounds, cornerRadius: 4).cgPath
            }
            let size = label.sizeThatFits(CGSize(width: 220, height: 30))
            label.frame = CGRect(x: r.midX - size.width / 2, y: r.maxY + 3, width: size.width, height: size.height)
        }
    }
}

private final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 5, dy: 2)) }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let s = super.sizeThatFits(size)
        return CGSize(width: s.width + 10, height: s.height + 4)
    }
}
