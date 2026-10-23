import SwiftUI

/// The picture behind every page: a softly blurred photo from the library, changing now and then, or the photo
/// the page is about (a folder's cover, the first photo of a list).
@MainActor
final class Backdrop: ObservableObject {
    @Published private(set) var photo: Int?
    private var pool: [Int] = []
    private var pinned: Int?
    private var timer: Task<Void, Never>?

    func start() {
        guard timer == nil else { return }
        timer = Task {
            while !Task.isCancelled {
                if pool.isEmpty, let j = try? await IopixClient.shared.json("api/random", query: [URLQueryItem(name: "n", value: "40")]) {
                    pool = (j["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
                }
                if pinned == nil, !pool.isEmpty { show(pool.removeFirst()) }
                try? await Task.sleep(nanoseconds: 40_000_000_000)
            }
        }
    }

    /// A page asks for its own photo while it is on screen.
    func pin(_ id: Int?) {
        pinned = id
        if let id { show(id) }
    }

    private func show(_ id: Int) {
        guard id != photo else { return }
        Task {
            _ = await ImageCache.shared.image("preview/\(id)")  // fetched first, so the change is a smooth fade
            withAnimation(.easeInOut(duration: 1.5)) { photo = id }
        }
    }
}

struct BackdropView: View {
    @EnvironmentObject private var backdrop: Backdrop

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.11, blue: 0.20)
            if let id = backdrop.photo {
                RemoteImage(path: "preview/\(id)")
                    .blur(radius: 40)
                    .saturation(1.4)
                    .scaleEffect(1.15)
                    .opacity(0.9)
                    .id(id)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.15), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Shows `photo` behind this page while it is on screen.
    func backdrop(_ photo: Int?) -> some View { modifier(BackdropPin(photo: photo)) }
}

private struct BackdropPin: ViewModifier {
    @EnvironmentObject private var backdrop: Backdrop
    let photo: Int?

    func body(content: Content) -> some View {
        content
            .onAppear { if let photo { backdrop.pin(photo) } }
            .onChange(of: photo) { _, p in if let p { backdrop.pin(p) } }
            .onDisappear { backdrop.pin(nil) }
    }
}
