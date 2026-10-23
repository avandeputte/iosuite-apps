import SwiftUI

/// The tabs along the top of the screen.
struct TVLibrary: View {
    let signedOut: () -> Void
    let switchProfile: () -> Void
    @StateObject private var store = LibraryStore()
    @StateObject private var backdrop = Backdrop()
    @StateObject private var clock = AmbientClock()
    @State private var ambient: ViewerStart?

    var body: some View {
        ZStack {
            BackdropView()
            TabView {
                NavigationStack { ForYouView() }.tabItem { Text("For You") }
                NavigationStack { FolderView(parent: nil, title: "Folders") }.tabItem { Text("Folders") }
                NavigationStack { AlbumsView() }.tabItem { Text("Albums") }
                NavigationStack { PeopleView() }.tabItem { Text("People") }
                NavigationStack { PlacesView() }.tabItem { Text("Places") }
                NavigationStack { YearsView() }.tabItem { Text("Years") }
                NavigationStack { SearchView() }.tabItem { Image(systemName: "magnifyingglass") }
                NavigationStack { SettingsTV(signedOut: signedOut, switchProfile: switchProfile, startAmbient: startAmbient) }
                    .tabItem { Image(systemName: "gearshape") }
            }
        }
        .environmentObject(store)
        .environmentObject(backdrop)
        .task { backdrop.start(); clock.start(); await store.load() }
        .onChange(of: clock.active) { _, on in if on { startAmbient() } }
        .fullScreenCover(item: $ambient, onDismiss: { clock.active = false; clock.touch() }) { PhotoViewer(start: $0).environmentObject(store) }
        .onOpenURL { url in openLink(url) }
    }

    /// Ambient mode: a slow slideshow from the chosen photos; any press on the remote ends it.
    private func startAmbient() {
        Task {
            var list = PhotoList()
            switch TVPrefs.shared.ambientSource {
            case .favorites:
                list = (try? await PhotoList.load([URLQueryItem(name: "fav", value: "1"), URLQueryItem(name: "type", value: "photo")])) ?? PhotoList()
            case .onThisDay:
                let c = Calendar.current.dateComponents([.month, .day], from: Date())
                list = (try? await PhotoList.load([URLQueryItem(name: "md", value: String(format: "%02d-%02d", c.month ?? 1, c.day ?? 1)),
                                                   URLQueryItem(name: "type", value: "photo")])) ?? PhotoList()
            case .rediscover:
                break
            }
            if list.ids.count < 5, let j = try? await IopixClient.shared.json("api/random", query: [URLQueryItem(name: "n", value: "60")]) {
                list = PhotoList(ids: (j["id"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue })
            }
            guard !list.ids.isEmpty else { clock.active = false; return }
            ambient = ViewerStart(list: list, index: 0, playing: true, ambient: true)
        }
    }

    /// iopix://photo/<id> from the Top Shelf: that photo, full screen.
    private func openLink(_ url: URL) {
        guard url.scheme == "iopix", url.host == "photo", let id = Int(url.lastPathComponent) else { return }
        ambient = ViewerStart(list: PhotoList(ids: [id]), index: 0, playing: false)
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
        .backdrop(parent.flatMap { p in store.folders.first { $0.id == p }?.cover })
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
    let switchProfile: () -> Void
    let startAmbient: () -> Void
    @ObservedObject private var prefs = TVPrefs.shared
    @State private var account: Account?

    var body: some View {
        Form {
            Section("Slideshows") {
                Picker("Each photo", selection: $prefs.slideSeconds) {
                    ForEach([3, 5, 6, 8, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Toggle("Shuffle", isOn: $prefs.shuffle)
                Toggle("Slow pan and zoom", isOn: $prefs.panAndZoom)
                Toggle("Play videos in slideshows", isOn: $prefs.playVideos)
            }
            Section {
                Picker("Start after", selection: $prefs.ambientMinutes) {
                    Text("Never").tag(0)
                    ForEach([2, 5, 10, 15, 30], id: \.self) { Text("\($0) minutes idle").tag($0) }
                }
                Picker("Show", selection: $prefs.ambientSource) {
                    ForEach(TVPrefs.AmbientSource.allCases) { Text($0.label).tag($0) }
                }
                Button("Start ambient mode now", action: startAmbient)
            } header: {
                Text("Ambient mode")
            } footer: {
                Text("A slow slideshow that starts by itself when the remote is left alone. Any button ends it.")
            }
            Section("Who's watching") {
                if let name = account?.name { Text("Signed in as \(name)") }
                Toggle("Ask who's watching when iopix opens", isOn: $prefs.askWhoIsWatching)
                Button("Switch to someone else", action: switchProfile)
                Button("Sign out") {
                    Task {
                        if let name = account?.name { Profiles.forget(name) }
                        await IopixClient.shared.signOut()
                        signedOut()
                    }
                }
            }
            Section("Server") {
                Text(AppConfig.serverURL.absoluteString)
            }
        }
        .frame(maxWidth: 1200)
        .navigationTitle("Settings")
        .task { account = try? await IopixClient.shared.account() }
    }
}

/// The photos of a folder, album, person or year, with a slideshow button.
struct PhotoGrid: View {
    let query: [URLQueryItem]
    var showsTitle = false
    var emptyText: String?
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
            } else if let list, list.ids.isEmpty, let emptyText {
                Text(emptyText).foregroundStyle(.secondary).padding(60)
            } else if list == nil {
                ProgressView().frame(maxWidth: .infinity).padding(60)
            }
        }
        .task {
            do { list = try await PhotoList.load(query) } catch { problem = error.localizedDescription }
        }
        .backdrop(list?.ids.first)
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
