import SwiftUI

/// The app's tabs, all native. Settings, Maintenance and editing a photo open the web app (under More).
struct AppTabs: View {
    @EnvironmentObject private var router: Router
    var showUploads: () -> Void

    var body: some View {
        TabView(selection: $router.tab) {
            ExploreView(showUploads: showUploads)
                .tabItem { Label(AppTab.explore.title, systemImage: AppTab.explore.symbol) }
                .tag(AppTab.explore)
            NavigationStack(path: $router.photosPath) {
                PhotoGridScreen(query: PhotoQuery(), title: "Photos", isRoot: true, showUploads: showUploads)
                    .navigationDestination(for: Screen.self) { ScreenView(destination: $0, showUploads: showUploads) }
            }
            .tabItem { Label(AppTab.photos.title, systemImage: AppTab.photos.symbol) }
            .tag(AppTab.photos)
            NavigationStack(path: $router.peoplePath) {
                PeopleScreen()
                    .navigationDestination(for: Screen.self) { ScreenView(destination: $0, showUploads: showUploads) }
            }
            .tabItem { Label(AppTab.people.title, systemImage: AppTab.people.symbol) }
            .tag(AppTab.people)
            NavigationStack(path: $router.placesPath) {
                PlacesScreen()
                    .navigationDestination(for: Screen.self) { ScreenView(destination: $0, showUploads: showUploads) }
            }
            .tabItem { Label(AppTab.places.title, systemImage: AppTab.places.symbol) }
            .tag(AppTab.places)
            MoreView(showUploads: showUploads)
                .tabItem { Label(AppTab.more.title, systemImage: AppTab.more.symbol) }
                .tag(AppTab.more)
        }
        .adaptableSidebar()
    }
}

/// The screen for a place a link leads to.
struct ScreenView: View {
    let destination: Screen
    var showUploads: () -> Void = {}

    var body: some View {
        switch destination {
        case .photos(let q, let title): PhotoGridScreen(query: q, title: title)
        case .folders(let parent): FoldersScreen(parent: parent)
        case .albums: AlbumsScreen()
        case .tags(let parent): TagsScreen(parent: parent)
        case .events: EventsScreen()
        case .map:
            PhotoMap { bbox in Router.shared.morePath.append(.photos(PhotoQuery([("bbox", bbox)]), title: "This area")) }
                .navigationTitle("Map").navigationBarTitleDisplayMode(.inline).ignoresSafeArea(edges: .bottom)
        case .web(let route):
            WebTabView(tab: .more, route: route, changeServer: showUploads)
                .navigationTitle(MoreView.title(of: route))
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private extension View {
    /// On iPad (iOS 18 and later) the tabs can become a sidebar.
    @ViewBuilder func adaptableSidebar() -> some View {
        if #available(iOS 18.0, *) { tabViewStyle(.sidebarAdaptable) } else { self }
    }
}

/// The rest of the library's pages, the web app's settings, and sending photos.
struct MoreView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var queue: UploadQueue
    var showUploads: () -> Void

    private struct Item: Identifiable {
        let title: String, symbol: String, hue: Color, destination: Screen
        var id: String { title }
    }

    private var library: [Item] {
        [Item(title: "Favorites", symbol: "heart.fill", hue: Hue.rose, destination: .photos(PhotoQuery([("fav", "1")]), title: "Favorites")),
         Item(title: "Folders", symbol: "folder.fill", hue: Hue.teal, destination: .folders(parent: nil)),
         Item(title: "Albums", symbol: "rectangle.stack.fill", hue: Hue.indigo, destination: .albums),
         Item(title: "Tags", symbol: "tag.fill", hue: Hue.orange, destination: .tags(parent: nil)),
         Item(title: "Map", symbol: "map.fill", hue: Hue.cyan, destination: .map),
         Item(title: "Events & trips", symbol: "calendar", hue: Hue.cyan, destination: .events)]
    }

    private var iopix: [Item] {
        var list = [Item(title: "Settings", symbol: "gearshape.fill", hue: Hue.slate, destination: .web("#/settings"))]
        if queue.account?.isAdmin == true {
            list.append(Item(title: "Maintenance", symbol: "wrench.and.screwdriver.fill", hue: Hue.slate, destination: .web("#/maintenance")))
        }
        return list
    }

    var body: some View {
        NavigationStack(path: $router.morePath) {
            List {
                Section { ForEach(library) { row($0) } }
                Section("iopix") { ForEach(iopix) { row($0) } }
                Section {
                    Button(action: showUploads) {
                        Label { Text("Send photos to iopix").foregroundStyle(.primary) } icon: { icon("square.and.arrow.up", Hue.blue) }
                    }
                }
            }
            .navigationTitle("More")
            .tint(.primary)
            .navigationDestination(for: Screen.self) { ScreenView(destination: $0, showUploads: showUploads) }
        }
    }

    private func row(_ i: Item) -> some View {
        Button { router.morePath.append(i.destination) } label: {
            Label { Text(i.title).foregroundStyle(.primary) } icon: { icon(i.symbol, i.hue) }
        }
    }

    private func icon(_ symbol: String, _ hue: Color) -> some View {
        Image(systemName: symbol).foregroundStyle(.white).font(.footnote)
            .frame(width: 28, height: 28).background(hue, in: RoundedRectangle(cornerRadius: 7))
    }

    static func title(of route: String) -> String {
        switch route.dropFirst(2).split(separator: "?").first.map(String.init) ?? "" {
        case "settings": return "Settings"
        case "maintenance": return "Maintenance"
        case "duplicates": return "Duplicate files"
        case "bursts": return "Bursts & best shots"
        case "detected": return "Detected content"
        case "photos": return "Edit in iopix"
        default: return "iopix"
        }
    }
}
