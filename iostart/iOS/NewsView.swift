import SwiftUI

/// The feeds: everything, the starred articles, then each folder with its feeds. A row opens its articles.
struct NewsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var news: NewsModel
    @Environment(\.scenePhase) private var phase

    @State private var following = false
    @State private var editing: Feed?
    @State private var leaving: Feed?

    private var folders: [(name: String, feeds: [Feed])] {
        let by = Dictionary(grouping: news.overview.feeds, by: \.folder)
        return by.keys.sorted { a, b in
            a.isEmpty != b.isEmpty ? !a.isEmpty : a.localizedCaseInsensitiveCompare(b) == .orderedAscending  // the feeds in no folder last
        }.map { ($0, by[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let problem = news.problem, news.loaded {
                    Label(problem, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.secondary)
                }
                if !news.overview.feeds.isEmpty {
                    Section {
                        NavigationLink(value: NewsScope.all) { ScopeRow(icon: "dot.radiowaves.up.forward", name: "All feeds", count: news.overview.unread) }
                        NavigationLink(value: NewsScope.starred) { ScopeRow(icon: "star", name: "Starred", count: news.overview.starred, quiet: true) }
                    }
                    ForEach(folders, id: \.name) { folder in
                        Section {
                            if !folder.name.isEmpty && folder.feeds.count > 1 {
                                NavigationLink(value: NewsScope.folder(folder.name)) {
                                    ScopeRow(icon: "folder", name: "All of \(folder.name)", count: folder.feeds.reduce(0) { $0 + $1.unread })
                                }
                            }
                            ForEach(folder.feeds) { feed in
                                NavigationLink(value: NewsScope.feed(feed.id)) { FeedRow(feed: feed) }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) { leaving = feed } label: { Label("Unfollow", systemImage: "trash") }
                                        Button { editing = feed } label: { Label("Edit", systemImage: "pencil") }.tint(.indigo)
                                    }
                                    .contextMenu {
                                        Button { editing = feed } label: { Label("Rename or move", systemImage: "pencil") }
                                        if let site = feed.site.flatMap({ URL(string: $0) }) {
                                            Button { model.open(site) } label: { Label("Open the site", systemImage: "safari") }
                                        }
                                        Button(role: .destructive) { leaving = feed } label: { Label("Unfollow", systemImage: "trash") }
                                    }
                            }
                        } header: {
                            if !folder.name.isEmpty { Text(folder.name) } else if folders.count > 1 { Text("Feeds") }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay { emptyState }
            .navigationTitle("News")
            .navigationDestination(for: NewsScope.self) { ArticleListView(scope: $0) }
            .refreshable { await news.refresh(model.account, look: true) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { following = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Follow a feed")
                        .disabled(!news.loaded)
                }
            }
            .sheet(isPresented: $following) { FollowSheet(folders: news.overview.folders) }
            .sheet(item: $editing) { FeedEditor(feed: $0, folders: news.overview.folders) }
            .confirmationDialog(leaving.map { "Stop following “\($0.title)”?" } ?? "", isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }), titleVisibility: .visible) {
                Button("Unfollow", role: .destructive) {
                    if let feed = leaving { Task { await unfollow(feed) } }
                }
            } message: {
                Text("Its articles go from your reader, on the start page too.")
            }
        }
        .task { await news.refresh(model.account) }
        .onChange(of: phase) { _, now in
            if now == .active { Task { await news.refresh(model.account) } }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !news.loaded {
            if let problem = news.problem {
                ContentUnavailableView {
                    Label("Your feeds are not available", systemImage: "dot.radiowaves.up.forward")
                } description: {
                    Text(problem)
                } actions: {
                    Button("Try again") { Task { await news.refresh(model.account) } }
                }
            } else {
                ProgressView()
            }
        } else if news.overview.feeds.isEmpty {
            ContentUnavailableView {
                Label("No feeds yet", systemImage: "dot.radiowaves.up.forward")
            } description: {
                Text("Follow a site's feed here, or on the Feeds page of your start page: they are the same.")
            } actions: {
                Button("Follow a feed") { following = true }
            }
        }
    }

    private func unfollow(_ feed: Feed) async {
        guard let account = model.account else { return }
        do {
            try await API(account: account).unfollow(feed.id)
        } catch {
            model.problem = NewsModel.told(error)
        }
        await news.refresh(account)
    }
}

private struct ScopeRow: View {
    let icon: String
    let name: String
    let count: Int
    var quiet = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 28)
            Text(name).lineLimit(1)
            Spacer()
            if count > 0 { Text("\(count)").font(.footnote.weight(quiet ? .regular : .semibold)).foregroundStyle(quiet ? .secondary : .primary).monospacedDigit() }
        }
    }
}

private struct FeedRow: View {
    let feed: Feed

    var body: some View {
        HStack(spacing: 12) {
            FeedIcon(feed: feed)
            Text(feed.title).lineLimit(1)
            if feed.error != nil {
                Image(systemName: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    .accessibilityLabel("Not read the last time")
            }
            Spacer()
            if feed.unread > 0 { Text("\(feed.unread)").font(.footnote.weight(.semibold)).monospacedDigit() }
        }
    }
}

/// A feed's icon: its site's own, as the start page keeps it, else the feed sign.
struct FeedIcon: View {
    @EnvironmentObject private var model: AppModel
    let feed: Feed
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit().padding(3)
            } else {
                Image(systemName: "dot.radiowaves.up.forward").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .task(id: feed.icon) {
            guard let account = model.account, let path = feed.icon else { return }
            image = await IconStore.shared.icon(at: path, site: feed.site ?? feed.url ?? "", account: account)
        }
    }
}

/// Follow a feed: its address, or its site's (the start page finds the feed).
private struct FollowSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var news: NewsModel
    @Environment(\.dismiss) private var dismiss
    let folders: [String]

    @State private var address = ""
    @State private var folder = ""
    @State private var busy = false
    @State private var problem: String?
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("example.com or a feed's address", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($typing)
                } footer: {
                    Text(problem ?? "A site's address is enough: the start page finds its feed.")
                        .foregroundStyle(problem == nil ? Color.secondary : Color.red)
                }
                FolderField(folder: $folder, folders: folders)
            }
            .onAppear { typing = true }
            .navigationTitle("Follow a feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Follow") { Task { await follow() } }
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func follow() async {
        guard let account = model.account else { return }
        busy = true
        defer { busy = false }
        var url = address.trimmingCharacters(in: .whitespaces)
        if !url.contains("://") { url = "https://" + url }
        do {
            _ = try await API(account: account).follow(url, folder: folder.trimmingCharacters(in: .whitespaces))
            await news.refresh(account)
            dismiss()
        } catch {
            problem = NewsModel.told(error)
        }
    }
}

/// A folder's name: typed, or picked from the ones there are.
private struct FolderField: View {
    @Binding var folder: String
    let folders: [String]

    var body: some View {
        Section {
            TextField("No folder", text: $folder)
            if !folders.isEmpty {
                Menu("Choose a folder") {
                    Button("No folder") { folder = "" }
                    ForEach(folders, id: \.self) { name in Button(name) { folder = name } }
                }
            }
        } header: {
            Text("Folder")
        }
    }
}

/// A feed's name, its folder, and whether its headlines show on the start page.
private struct FeedEditor: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var news: NewsModel
    @Environment(\.dismiss) private var dismiss
    let feed: Feed
    let folders: [String]

    @State private var title = ""
    @State private var folder = ""
    @State private var onStart = true
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(feed.feedTitle ?? "The feed's own name", text: $title)
                } header: {
                    Text("Name")
                } footer: {
                    Text(problem ?? "Empty: the feed's own name.").foregroundStyle(problem == nil ? Color.secondary : Color.red)
                }
                FolderField(folder: $folder, folders: folders)
                Section {
                    Toggle("Headlines on the start page", isOn: $onStart)
                } footer: {
                    if let error = feed.error { Text("Not read the last time: \(error)") }
                }
            }
            .navigationTitle("Edit feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Save") { Task { await save() } } }
                }
            }
            .onAppear {
                title = feed.title == (feed.feedTitle ?? feed.url ?? "") ? "" : feed.title
                folder = feed.folder
                onStart = feed.onStart
            }
        }
    }

    private func save() async {
        guard let account = model.account else { return }
        busy = true
        defer { busy = false }
        do {
            try await API(account: account).change(feed.id, .init(title: title.trimmingCharacters(in: .whitespaces), folder: folder.trimmingCharacters(in: .whitespaces), onStart: onStart))
            await news.refresh(account)
            dismiss()
        } catch {
            problem = NewsModel.told(error)
        }
    }
}
