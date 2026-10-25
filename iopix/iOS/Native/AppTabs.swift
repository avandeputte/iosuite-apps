import SwiftUI

/// The app's tabs. Explore is native; Photos, People, Places and the pages under More show the web app until they
/// get native screens of their own.
struct AppTabs: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var queue: UploadQueue
    var showUploads: () -> Void

    var body: some View {
        TabView(selection: $router.tab) {
            ExploreView(showUploads: showUploads)
                .tabItem { Label(AppTab.explore.title, systemImage: AppTab.explore.symbol) }
                .tag(AppTab.explore)
            ForEach([AppTab.photos, .people, .places], id: \.self) { t in
                WebTabView(tab: t, changeServer: showUploads)
                    .tabItem { Label(t.title, systemImage: t.symbol) }
                    .tag(t)
            }
            MoreView(showUploads: showUploads)
                .tabItem { Label(AppTab.more.title, systemImage: AppTab.more.symbol) }
                .tag(AppTab.more)
        }
        .adaptableSidebar()
    }
}

private extension View {
    /// On iPad (iOS 18 and later) the tabs can become a sidebar.
    @ViewBuilder func adaptableSidebar() -> some View {
        if #available(iOS 18.0, *) { tabViewStyle(.sidebarAdaptable) } else { self }
    }
}

/// The rest of the web app's destinations, and sending photos.
struct MoreView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var queue: UploadQueue
    var showUploads: () -> Void

    private struct Item: Identifiable {
        let title: String, symbol: String, hue: Color, route: String
        var id: String { route }
    }

    private var items: [Item] {
        var list = [
            Item(title: "Favorites", symbol: "heart.fill", hue: Hue.rose, route: "#/photos?fav=1"),
            Item(title: "Folders", symbol: "folder.fill", hue: Hue.teal, route: "#/folders"),
            Item(title: "Albums", symbol: "rectangle.stack.fill", hue: Hue.indigo, route: "#/albums"),
            Item(title: "Tags", symbol: "tag.fill", hue: Hue.orange, route: "#/tags"),
            Item(title: "Map", symbol: "map.fill", hue: Hue.cyan, route: "#/map"),
            Item(title: "Events & trips", symbol: "calendar", hue: Hue.cyan, route: "#/events"),
            Item(title: "Settings", symbol: "gearshape.fill", hue: Hue.slate, route: "#/settings"),
        ]
        if queue.account?.isAdmin == true {
            list.append(Item(title: "Maintenance", symbol: "wrench.and.screwdriver.fill", hue: Hue.slate, route: "#/maintenance"))
        }
        return list
    }

    var body: some View {
        NavigationStack(path: $router.morePath) {
            List {
                Section {
                    ForEach(items) { i in
                        Button { open(i.route) } label: {
                            Label { Text(i.title).foregroundStyle(.primary) } icon: {
                                Image(systemName: i.symbol).foregroundStyle(.white).font(.footnote)
                                    .frame(width: 28, height: 28).background(i.hue, in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }
                }
                Section {
                    Button(action: showUploads) {
                        Label { Text("Send photos to iopix").foregroundStyle(.primary) } icon: {
                            Image(systemName: "square.and.arrow.up").foregroundStyle(.white).font(.footnote)
                                .frame(width: 28, height: 28).background(Hue.blue, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }
            .navigationTitle("More")
            .navigationDestination(for: String.self) { route in
                WebTabView(tab: .more, route: route, changeServer: showUploads)
                    .navigationTitle(title(of: route))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func open(_ route: String) {
        if route.hasPrefix("#/photos") { router.open(route) } else { router.morePath = [route] }
    }

    private func title(of route: String) -> String {
        items.first { $0.route == route }?.title ?? {
            switch route.dropFirst(2).split(separator: "?").first.map(String.init) ?? "" {
            case "duplicates": return "Duplicate files"
            case "bursts": return "Bursts & best shots"
            case "detected": return "Detected content"
            default: return "iopix"
            }
        }()
    }
}
