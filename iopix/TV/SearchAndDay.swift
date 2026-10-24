import SwiftUI

/// Photos taken on today's date in earlier years, grouped by year (newest first).
struct OnThisDayView: View {
    @State private var list: PhotoList?
    @State private var viewer: ViewerStart?
    @State private var day = Date()

    var body: some View {
        ScrollView {
            if let list {
                if list.ids.isEmpty {
                    Text("Nothing was taken on this day in earlier years.").foregroundStyle(.secondary).padding(80)
                } else {
                    Button { viewer = ViewerStart(list: list, index: 0, playing: true) } label: {
                        Label("Slideshow", systemImage: "play.fill")
                    }
                    .padding(.bottom, 30)
                    ForEach(groups(list), id: \.year) { g in
                        VStack(alignment: .leading, spacing: 24) {
                            Text(caption(g.year)).font(.title3.bold()).padding(.horizontal, 60)
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 30) {
                                    ForEach(g.indices, id: \.self) { i in
                                        Button { viewer = ViewerStart(list: list, index: i, playing: false) } label: {
                                            RemoteImage(path: "thumb/\(list.ids[i])").frame(width: 360, height: 240)
                                        }
                                        .buttonStyle(.card)
                                    }
                                }
                                .padding(.horizontal, 60).padding(.vertical, 30)
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }
            } else {
                ProgressView().padding(80)
            }
        }
        .navigationTitle("On this day · \(day.formatted(.dateTime.month(.wide).day()))")
        .task {
            day = Date()
            let md = String(format: "%02d-%02d", Calendar.current.component(.month, from: day), Calendar.current.component(.day, from: day))
            list = (try? await PhotoList.load([URLQueryItem(name: "md", value: md), URLQueryItem(name: "sort", value: "new")])) ?? PhotoList()
        }
        .fullScreenCover(item: $viewer) { PhotoViewer(start: $0) }
    }

    private func groups(_ list: PhotoList) -> [(year: Int, indices: [Int])] {
        var by: [Int: [Int]] = [:]
        for i in list.ids.indices {
            let t = i < list.times.count ? list.times[i] : 0
            let year = t > 0 ? Calendar.current.component(.year, from: Date(timeIntervalSince1970: t)) : 0  // 0: date unknown
            by[year, default: []].append(i)
        }
        return by.keys.sorted(by: >).map { ($0, by[$0]!) }
    }

    private func caption(_ year: Int) -> String {
        guard year > 0 else { return "Date unknown" }
        let ago = Calendar.current.component(.year, from: Date()) - year
        return ago <= 0 ? "This year" : ago == 1 ? "\(year) · a year ago" : "\(year) · \(ago) years ago"
    }
}

/// Search, as in iopix's own search box: words match names, tags, places, folders, captions; "looks like"
/// finds photos by what is in them, when the server has content search turned on. People and folders whose
/// name matches are shown first.
struct SearchView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var text = ""
    @State private var query = ""
    @State private var debounce: Task<Void, Never>?

    var body: some View {
        ScrollView {
            if query.isEmpty {
                Text("Search for people, places, tags, folders, or what's in the photo.")
                    .foregroundStyle(.secondary).padding(80)
            } else {
                let people = store.people.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(12)
                let folders = store.folders.filter { $0.name.localizedCaseInsensitiveContains(query) && $0.count > 0 }.prefix(12)
                if !people.isEmpty {
                    section("People") {
                        ForEach(Array(people)) { p in
                            NavigationLink(value: p) { CoverCard(title: p.name, subtitle: "\(p.count)", image: p.face.map { "face/\($0)" }, round: true) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                if !folders.isEmpty {
                    section("Folders") {
                        ForEach(Array(folders)) { f in
                            NavigationLink(value: f) { CoverCard(title: f.name, subtitle: "\(f.count)", image: f.cover.map { "thumb/\($0)" }) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Text("Photos").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 60)
                PhotoGrid(query: [URLQueryItem(name: "q", value: query)], emptyText: "No photos match “\(query)”.")
                    .id("q:" + query)
                LooksLike(query: query).id("sem:" + query)
            }
        }
        .searchable(text: $text, prompt: "People, places, tags, things")
        .onChange(of: text) { _, t in
            debounce?.cancel()
            debounce = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                if !Task.isCancelled { query = t.trimmingCharacters(in: .whitespaces) }
            }
        }
        .navigationDestination(for: Person.self) { p in
            ScrollView { PhotoGrid(query: [URLQueryItem(name: "tag", value: String(p.id))]) }.navigationTitle(p.name)
        }
        .navigationDestination(for: Folder.self) { FolderView(parent: $0.id, title: $0.name) }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title3.bold()).padding(.horizontal, 60)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 40) { content() }.padding(.horizontal, 60).padding(.vertical, 30)
            }
        }
    }
}

/// "Looks like …": the content search, shown only when it finds something.
struct LooksLike: View {
    let query: String
    @State private var list: PhotoList?
    @State private var viewer: ViewerStart?

    var body: some View {
        Group {
            if let list, !list.ids.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Looks like “\(query)”").font(.title3.bold()).padding(.horizontal, 60)
                    PhotoTiles(list: list) { viewer = ViewerStart(list: list, index: $0, playing: false) }
                }
            }
        }
        .task { list = try? await PhotoList.load([URLQueryItem(name: "sem", value: query)]) }
        .fullScreenCover(item: $viewer) { PhotoViewer(start: $0) }
    }
}
