import SwiftUI

/// The app's tabs, all native. Editing a photo opens the web app (under More).
struct AppTabs: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var queue: UploadQueue
    @Environment(\.horizontalSizeClass) private var width
    var showUploads: () -> Void

    var body: some View {
        Group {
            if width == .regular {
                SidebarLayout(showUploads: showUploads)  // iPad and Mac: every page listed in the sidebar
            } else {
                tabs
            }
        }
        .hardTopEdge()
    }

    private var tabs: some View {
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
                FacesPeopleScreen()
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
    }
}

/// On a wide screen the pages are listed in a sidebar, every one of them, instead of a tab bar with a More tab.
struct SidebarLayout: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var queue: UploadQueue
    var showUploads: () -> Void

    /// A sidebar row: one of the main tabs, or a page from More.
    enum Item: Hashable {
        case tab(AppTab)
        case page(Screen)
    }

    /// The sidebar's selection, read from and written to the router (so links from anywhere pick the right row).
    private var selection: Binding<Item?> {
        Binding(
            get: { router.tab == .more ? router.morePath.first.map(Item.page) ?? .page(.albums) : .tab(router.tab) },
            set: { item in
                switch item {
                case .tab(let t): router.tab = t
                case .page(let s): router.tab = .more; router.morePath = [s]
                case nil: break
                }
            })
    }

    private struct Row: Identifiable {
        let title: String, symbol: String, hue: Color, screen: Screen
        var id: Screen { screen }
    }

    private var library: [Row] {
        let rows = [Row(title: "Favorites", symbol: "heart.fill", hue: Hue.rose, screen: .photos(PhotoQuery([("fav", "1")]), title: "Favorites")),
                    Row(title: "Folders", symbol: "folder.fill", hue: Hue.teal, screen: .folders(parent: nil)),
                    Row(title: "Albums", symbol: "rectangle.stack.fill", hue: Hue.indigo, screen: .albums),
                    Row(title: "Tags", symbol: "tag.fill", hue: Hue.orange, screen: .tags(parent: nil)),
                    Row(title: "Map", symbol: "map.fill", hue: Hue.cyan, screen: .map),
                    Row(title: "Events & trips", symbol: "calendar", hue: Hue.cyan, screen: .events)]
        return rows
    }

    /// Looking after the library: for admins only, in a group of its own under Library.
    private var management: [Row] {
        guard queue.account?.isAdmin == true else { return [] }
        return [Row(title: "Import", symbol: "square.and.arrow.down.on.square", hue: Hue.blue, screen: .importPhotos),
                Row(title: "Trash", symbol: "trash", hue: Hue.rose, screen: .trash),
                Row(title: "Near-duplicates", symbol: "square.on.square", hue: Hue.orange, screen: .nearDuplicates),
                Row(title: "Detected content", symbol: "sparkles", hue: Hue.purple, screen: .detected),
                Row(title: "History", symbol: "clock.arrow.circlepath", hue: Hue.slate, screen: .history(photo: nil))]
    }

    private var iopix: [Row] {
        var rows = [Row(title: "Settings", symbol: "gearshape.fill", hue: Hue.slate, screen: .settings)]
        if queue.account?.isAdmin == true { rows.append(Row(title: "Tools", symbol: "wrench.and.screwdriver.fill", hue: Hue.slate, screen: .tools)) }
        return rows
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    ForEach([AppTab.explore, .photos, .people, .places], id: \.self) { t in
                        Label(t.title, systemImage: t.symbol).tag(Item.tab(t))
                    }
                }
                Section("Library") { ForEach(library) { row($0) } }
                if !management.isEmpty { Section("Library management") { ForEach(management) { row($0) } } }
                Section("ioPix") {
                    ForEach(iopix) { row($0) }
                    Button(action: showUploads) {
                        Label { Text("Send photos to ioPix").foregroundStyle(.primary) } icon: { icon("square.and.arrow.up", Hue.blue) }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("ioPix")
        } detail: {
            detail
        }
    }

    private func row(_ r: Row) -> some View {
        Label { Text(r.title) } icon: { icon(r.symbol, r.hue) }.tag(Item.page(r.screen))
    }

    private func icon(_ symbol: String, _ hue: Color) -> some View {
        Image(systemName: symbol).foregroundStyle(.white).font(.caption)
            .frame(width: 24, height: 24).background(hue, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var detail: some View {
        switch router.tab {
        case .explore:
            ExploreView(showUploads: showUploads)
        case .photos:
            NavigationStack(path: $router.photosPath) {
                PhotoGridScreen(query: PhotoQuery(), title: "Photos", isRoot: true, showUploads: showUploads)
                    .navigationDestination(for: Screen.self) { ScreenView(destination: $0, showUploads: showUploads) }
            }
        case .people:
            NavigationStack(path: $router.peoplePath) {
                FacesPeopleScreen()
                    .navigationDestination(for: Screen.self) { ScreenView(destination: $0, showUploads: showUploads) }
            }
        case .places:
            NavigationStack(path: $router.placesPath) {
                PlacesScreen()
                    .navigationDestination(for: Screen.self) { ScreenView(destination: $0, showUploads: showUploads) }
            }
        case .more:
            // the chosen page is the stack's root; what it opens goes on after it in morePath
            let root = router.morePath.first ?? .albums
            NavigationStack(path: Binding(get: { Array(router.morePath.dropFirst()) }, set: { router.morePath = [root] + $0 })) {
                ScreenView(destination: root, showUploads: showUploads)
                    .navigationDestination(for: Screen.self) { ScreenView(destination: $0, showUploads: showUploads) }
            }
            .id(root)
        }
    }
}

/// The screen for a place a link leads to.
struct ScreenView: View {
    let destination: Screen
    var showUploads: () -> Void = {}

    var body: some View {
        switch destination {
        case .photos(let q, let title): PhotoGridScreen(query: q, title: title)
        case .folders(let parent): ManageFoldersScreen(parent: parent)
        case .albums: ManageAlbumsScreen()
        case .tags(let parent): ManageTagsScreen(parent: parent)
        case .events: EventsScreen()
        case .trash: ManageTrashScreen()
        case .importPhotos: ManageImportScreen()
        case .duplicates: ManageDuplicatesScreen()
        case .nearDuplicates: ManageNearDuplicatesScreen()
        case .detected: ManageDetectedScreen()
        case .quality: ManageQualityScreen()
        case .dateSuggest: ManageDateSuggestScreen()
        case .placeSuggest: ManagePlaceSuggestScreen()
        case .jerseys: ManagePersonSuggestScreen(kind: .jersey)
        case .clothing: ManagePersonSuggestScreen(kind: .clothing)
        case .rotation: ManageRotationScreen()
        case .damaged: AdminDamagedScreen(canEdit: true)
        case .history(let photo): ManageHistoryScreen(photo: photo)
        case .faces(let tab): FacesReviewScreen(tab: tab)
        case .settings: AdminSettingsScreen()
        case .tools: AdminToolsScreen()
        case .consistency: AdminConsistencyScreen()
        case .map:
            PhotoMap { bbox in Router.shared.morePath.append(.photos(PhotoQuery([("bbox", bbox)]), title: "This area")) }
                .navigationTitle("Map").navigationBarTitleDisplayMode(.inline).ignoresSafeArea(edges: .bottom)
                .globalSearch()
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
        var list = [Item(title: "Settings", symbol: "gearshape.fill", hue: Hue.slate, destination: .settings)]
        if queue.account?.isAdmin == true {
            list.append(Item(title: "Tools", symbol: "wrench.and.screwdriver.fill", hue: Hue.slate, destination: .tools))
        }
        return list
    }

    var body: some View {
        NavigationStack(path: $router.morePath) {
            List {
                Section("Library") { ForEach(library) { row($0) } }
                ManageMoreSection()
                Section("ioPix") { ForEach(iopix) { row($0) } }
                Section {
                    Button(action: showUploads) {
                        Label { Text("Send photos to ioPix").foregroundStyle(.primary) } icon: { icon("square.and.arrow.up", Hue.blue) }
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
        case "tools": return "Tools"
        case "duplicates": return "Duplicate files"
        case "detected": return "Detected content"
        case "photos": return "Edit in ioPix"
        default: return "ioPix"
        }
    }
}

extension View {
    /// A plain edge under the bar at the top instead of the soft blur that smears the page's first row (the
    /// filter chips, a heading) while it sits under the bar.
    @ViewBuilder func hardTopEdge() -> some View {
        if #available(iOS 26.0, macCatalyst 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }
}
