import SwiftUI

/// The tabs along the top of the screen.
struct TVLibrary: View {
    let signedOut: () -> Void
    @StateObject private var store = LibraryStore()

    var body: some View {
        TabView {
            RediscoverView().tabItem { Text("Rediscover") }
            NavigationStack { FolderView(parent: nil, title: "Folders") }.tabItem { Text("Folders") }
            NavigationStack { AlbumsView() }.tabItem { Text("Albums") }
            NavigationStack { PeopleView() }.tabItem { Text("People") }
            NavigationStack { YearsView() }.tabItem { Text("Years") }
            SettingsTV(signedOut: signedOut).tabItem { Text("Settings") }
        }
        .environmentObject(store)
        .task { await store.load() }
    }
}

/// A big square card: a picture and a caption under it.
struct CoverCard: View {
    let title: String
    var subtitle: String?
    let image: String?
    var round = false

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let image { RemoteImage(path: image) } else { Color.white.opacity(0.08) }
            }
            .frame(width: round ? 220 : 340, height: round ? 220 : 230)
            .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 12)))
            Text(title).lineLimit(1).frame(width: round ? 260 : 340)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

let gridColumns = [GridItem(.adaptive(minimum: 340, maximum: 360), spacing: 48)]

struct FolderView: View {
    @EnvironmentObject private var store: LibraryStore
    let parent: Int?
    let title: String

    var body: some View {
        let subs = store.children(of: parent)
        ScrollView {
            if let problem = store.problem { Text(problem).foregroundStyle(.secondary).padding() }
            if !subs.isEmpty {
                LazyVGrid(columns: gridColumns, spacing: 60) {
                    ForEach(subs) { f in
                        NavigationLink(value: f) {
                            CoverCard(title: f.name, subtitle: "\(f.count)", image: f.cover.map { "thumb/\($0)" })
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 60)
            }
            if let parent {
                PhotoGrid(query: [URLQueryItem(name: "album", value: String(parent))], showsTitle: !subs.isEmpty)
            }
        }
        .navigationTitle(title)
        .navigationDestination(for: Folder.self) { FolderView(parent: $0.id, title: $0.name) }
    }
}

struct AlbumsView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 60) {
                if store.favorites > 0 {
                    NavigationLink(value: Album(id: -1, name: "Favorites", count: store.favorites, cover: nil)) {
                        CoverCard(title: "Favorites", subtitle: "\(store.favorites)", image: nil)
                            .overlay(Image(systemName: "heart.fill").font(.system(size: 70)).offset(y: -40))
                    }
                    .buttonStyle(.borderless)
                }
                ForEach(store.albums) { a in
                    NavigationLink(value: a) {
                        CoverCard(title: a.name, subtitle: "\(a.count)", image: a.cover.map { "thumb/\($0)" })
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(60)
            if store.albums.isEmpty && store.favorites == 0 {
                Text("No albums yet. Albums you make in iopix show up here.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Albums")
        .navigationDestination(for: Album.self) { a in
            ScrollView {
                PhotoGrid(query: a.id < 0 ? [URLQueryItem(name: "fav", value: "1")] : [URLQueryItem(name: "ualbum", value: String(a.id))])
            }
            .navigationTitle(a.name)
        }
    }
}

struct PeopleView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 280), spacing: 40)], spacing: 50) {
                ForEach(store.people) { p in
                    NavigationLink(value: p) {
                        CoverCard(title: p.name, subtitle: "\(p.count)", image: p.face.map { "face/\($0)" }, round: true)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(60)
        }
        .navigationTitle("People")
        .navigationDestination(for: Person.self) { p in
            ScrollView { PhotoGrid(query: [URLQueryItem(name: "tag", value: String(p.id))]) }
                .navigationTitle(p.name)
        }
    }
}

struct YearsView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 40)], spacing: 40) {
                ForEach(store.years, id: \.year) { y in
                    NavigationLink(value: y.year) {
                        VStack {
                            Text(String(y.year)).font(.title2.bold())
                            Text("\(y.count) photos").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 300, height: 160)
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(60)
        }
        .navigationTitle("Years")
        .navigationDestination(for: Int.self) { y in
            ScrollView { PhotoGrid(query: [URLQueryItem(name: "year", value: String(y))]) }
                .navigationTitle(String(y))
        }
    }
}

struct RediscoverView: View {
    @State private var list = PhotoList()
    @State private var viewer: ViewerStart?

    var body: some View {
        ScrollView {
            HStack(spacing: 30) {
                Button { viewer = ViewerStart(list: list, index: 0, playing: true) } label: { Label("Slideshow", systemImage: "play.fill") }
                    .disabled(list.ids.isEmpty)
                Button { Task { await shuffle() } } label: { Label("Shuffle", systemImage: "shuffle") }
            }
            .padding(.top, 20)
            PhotoTiles(list: list) { viewer = ViewerStart(list: list, index: $0, playing: false) }
        }
        .task { if list.ids.isEmpty { await shuffle() } }
        .fullScreenCover(item: $viewer) { PhotoViewer(start: $0) }
    }

    private func shuffle() async {
        guard let j = try? await IopixClient.shared.json("api/random", query: [URLQueryItem(name: "n", value: "60")]) else { return }
        list = PhotoList(ids: (j["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue })
    }
}

struct SettingsTV: View {
    let signedOut: () -> Void
    @State private var account: Account?

    var body: some View {
        VStack(spacing: 40) {
            Text("iopix").font(.title2.bold())
            Text(AppConfig.serverURL.absoluteString).foregroundStyle(.secondary)
            if let name = account?.name { Text("Signed in as \(name)") }
            Button("Sign out") {
                Task {
                    await IopixClient.shared.signOut()
                    signedOut()
                }
            }
        }
        .task { account = try? await IopixClient.shared.account() }
    }
}

/// The photos of a folder, album, person or year, with a slideshow button.
struct PhotoGrid: View {
    let query: [URLQueryItem]
    var showsTitle = false
    @State private var list: PhotoList?
    @State private var viewer: ViewerStart?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if let list, !list.ids.isEmpty {
                HStack(spacing: 30) {
                    if showsTitle { Text("\(list.ids.count) photos here").font(.headline) }
                    Button { viewer = ViewerStart(list: list, index: 0, playing: true) } label: {
                        Label("Slideshow", systemImage: "play.fill")
                    }
                }
                .padding(.horizontal, 60)
                PhotoTiles(list: list) { viewer = ViewerStart(list: list, index: $0, playing: false) }
            } else if let problem {
                Text(problem).foregroundStyle(.secondary).padding(60)
            } else if list == nil {
                ProgressView().frame(maxWidth: .infinity).padding(60)
            }
        }
        .task {
            do { list = try await PhotoList.load(query) } catch { problem = error.localizedDescription }
        }
        .fullScreenCover(item: $viewer) { PhotoViewer(start: $0) }
    }
}

struct PhotoTiles: View {
    let list: PhotoList
    let open: (Int) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 300), spacing: 30)], spacing: 30) {
            ForEach(Array(list.ids.enumerated()), id: \.offset) { i, id in
                Button { open(i) } label: {
                    RemoteImage(path: "thumb/\(id)")
                        .frame(width: 290, height: 194)
                        .overlay(alignment: .bottomLeading) {
                            if list.isVideo(i) {
                                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white).shadow(radius: 4).padding(10)
                            }
                        }
                }
                .buttonStyle(.card)
            }
        }
        .padding(.horizontal, 60)
        .padding(.bottom, 60)
    }
}
