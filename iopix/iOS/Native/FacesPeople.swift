import SwiftUI

/// Everyone named in the library, as the web app's People page: by group (the sections arranged in iopix), by
/// family name, by name or most photos first, in three sizes, with a search. The faces waiting for a decision are
/// one tap away. Editors arrange the groups: make, rename, reorder and delete them, and choose who is in each.
struct FacesPeopleScreen: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var queue: UploadQueue
    @Environment(\.horizontalSizeClass) private var width
    @AppStorage("people.sort") private var sort = "group"      // group, family, name, count
    @AppStorage("people.within") private var within = "arranged" // arranged, name, count
    @AppStorage("people.size") private var size = "m"
    @State private var tags: [FacesTag] = []
    @State private var groups: [PeopleGroup] = []
    @State private var canEdit = false
    @State private var arranging = false
    @State private var search = ""
    @State private var summary: [String: (photos: Int, faces: Int)] = [:]
    @State private var birthdays: [Birthday] = []
    @State private var openPerson: FacesTag?
    @State private var openFaces: String?
    @State private var asking: Ask?
    @State private var askText = ""
    @State private var deleting: PeopleGroup?
    @State private var note: String?
    @State private var problem: String?

    /// A birthday in the next month, from ioContacts (Settings › ioContacts): nothing shows when it is off or not reached.
    struct Birthday: Identifiable {
        let id: Int, turns: Int?, inDays: Int, date: String
        var when: String {
            if inDays == 0 { return "today" }
            if inDays == 1 { return "tomorrow" }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            guard let d = f.date(from: date) else { return date }
            return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    private enum Ask: Identifiable {
        case newGroup(with: Int?), rename(PeopleGroup)
        var id: String {
            switch self {
            case .newGroup(let p): return "new\(p ?? 0)"
            case .rename(let g): return "rename\(g.id)"
            }
        }
    }

    /// People with photos: person tags, not the People root and not a family that has people under it. Most photos
    /// first, as the web app lists them (the order of "Everyone else" when a section is shown as arranged).
    private var people: [FacesTag] { tags.filter { $0.isPerson && $0.own > 0 && !$0.hasKids }.sorted(by: byCount) }

    private var shown: [FacesTag] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? people : people.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var badge: CGFloat {
        let base: CGFloat = width == .regular ? 130 : 96
        return size == "s" ? base * 0.72 : size == "l" ? base * 1.4 : base
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                todo
                birthdayPills
                sections
                if let problem, tags.isEmpty {
                    Text(problem).foregroundStyle(.secondary).padding(.top, 40)
                } else if people.isEmpty && !tags.isEmpty {
                    Text("No people named yet. Name faces and they show here.").foregroundStyle(.secondary).padding(.top, 40)
                }
            }
            .padding(16)
        }
        .hardTopEdge()
        .navigationTitle("People")
        // the library search: typing narrows the people here too; Return or a suggestion opens the photos
        .globalSearch(text: $search)
        .toolbar { toolbar }
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(item: $openPerson) { FacesPersonScreen(tag: $0) }
        .navigationDestination(item: $openFaces) { FacesReviewScreen(tab: $0) }
        // back from the faces: the counts and the people named there are read again (and once more when the
        // library summary catches up with the server's reindexing)
        .onChange(of: openFaces) { _, now in if now == nil { Task { await load() } } }
        .onChange(of: store.people) { _, _ in Task { await load() } }
        .onChange(of: sort) { _, now in if now != "group" { arranging = false } }  // arranging is for the group view only
        .alert(askTitle, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            TextField("Name", text: $askText)
            Button("Cancel", role: .cancel) {}
            Button("OK") { let a = asking; Task { await answer(a) } }
        } message: {
            if case .newGroup = asking { Text("Family, Friends, Classmates…") }
        }
        .confirmationDialog("Delete the group “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let g = deleting { Task { await delete(g) } } }
        } message: { Text("The people in it stay; only the group goes.") }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) { Button("OK", role: .cancel) {} }
    }

    private var askTitle: String {
        switch asking {
        case .newGroup: return "New group"
        case .rename: return "Rename group"
        case nil: return ""
        }
    }

    // MARK: faces to decide

    @ViewBuilder private var todo: some View {
        let items: [(String, String, String)] = [
            ("suggested", "Suggestions to confirm", summary["suggested"].map { "\($0.faces.formatted()) in \($0.photos.formatted()) photos" } ?? ""),
            ("unknown", "Unnamed faces", summary["unknown"].map { "\($0.faces.formatted()) in \($0.photos.formatted()) photos" } ?? ""),
            ("ignored", "Ignored faces", summary["ignored"].map { $0.faces.formatted() } ?? ""),
        ].filter { k, _, _ in (summary[k]?.faces ?? 0) > 0 }
        if !items.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(items, id: \.0) { k, label, count in
                    Button { openFaces = k } label: {
                        HStack(spacing: 6) { Text(label); Text(count).bold() }
                            .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(Hue.amber).background(Hue.amber.opacity(0.13), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var birthdayPills: some View {
        let byId = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let list = birthdays.filter { byId[$0.id] != nil }
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Birthdays").font(.subheadline).foregroundStyle(.secondary)
                FlowLayout(spacing: 8) {
                    ForEach(list) { b in
                        let hue = b.inDays == 0 ? Hue.amber : Hue.blue
                        Button { openPerson = byId[b.id] } label: {
                            HStack(spacing: 6) {
                                RemoteImage(path: "face/\(b.id)").frame(width: 22, height: 22).clipShape(Circle())
                                Text(byId[b.id]?.name ?? "")
                                Text(b.turns.map { "turns \($0) \(b.when)" } ?? b.when).bold()
                            }
                            .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(hue).background(hue.opacity(0.13), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Photos of \(byId[b.id]?.name ?? "")")
                    }
                }
            }
        }
    }

    // MARK: sections

    @ViewBuilder private var sections: some View {
        let list = shown
        switch sort {
        case "family":
            let fams = Dictionary(grouping: list) { $0.family ?? "" }
            let names = fams.keys.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            ForEach(names, id: \.self) { f in section(f, ordered(fams[f] ?? [], arranged: false), group: nil) }
            if let none = fams[""], !none.isEmpty { section(names.isEmpty ? nil : "No family name", ordered(none, arranged: false), group: nil) }
        case "name", "count":
            section(nil, list.sorted(by: sort == "name" ? byName : byCount), group: nil)
        default:
            if groups.isEmpty && !arranging {
                section(nil, list.sorted(by: byCount), group: nil)
            } else {
                let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                ForEach(groups) { g in
                    let members = g.members.compactMap { byID[$0] }
                    if !members.isEmpty || arranging { section(g.name, arranging ? members : ordered(members, arranged: true), group: g) }
                }
                let placed = Set(groups.flatMap(\.members))
                let rest = list.filter { !placed.contains($0.id) }
                if !rest.isEmpty || arranging {
                    section(groups.isEmpty ? nil : "Everyone else", within == "name" ? rest.sorted(by: byName) : rest, group: nil)
                }
            }
        }
    }

    private func byName(_ a: FacesTag, _ b: FacesTag) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
    private func byCount(_ a: FacesTag, _ b: FacesTag) -> Bool { a.all > b.all }

    private func ordered(_ list: [FacesTag], arranged: Bool) -> [FacesTag] {
        switch within {
        case "name": return list.sorted(by: byName)
        case "count": return list.sorted(by: byCount)
        default: return arranged ? list : list.sorted(by: byName)
        }
    }

    @ViewBuilder private func section(_ title: String?, _ list: [FacesTag], group: PeopleGroup?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 8) {
                    Text(title).font(.title3.bold())
                    Text("\(list.count)").foregroundStyle(.secondary)
                    Spacer()
                    if arranging, let g = group { groupMenu(g) }
                }
            }
            if arranging && group != nil && list.isEmpty {
                Text("Add people with a person's ⋯ menu.").font(.footnote).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: badge), spacing: 14)], spacing: 16) {
                ForEach(list) { t in card(t, in: group) }
            }
        }
    }

    private func card(_ t: FacesTag, in group: PeopleGroup?) -> some View {
        Button { openPerson = t } label: {
            VStack(spacing: 6) {
                FaceImage(person: t.person).aspectRatio(1, contentMode: .fit).clipShape(Circle())
                    .overlay(alignment: .topTrailing) {
                        if arranging { Image(systemName: "ellipsis.circle.fill").font(.title3).symbolRenderingMode(.multicolor).foregroundStyle(.white, Color.accentColor) }
                    }
                Text(t.name).font(size == "s" ? .caption2 : .caption).lineLimit(2).multilineTextAlignment(.center)
                    .frame(height: size == "s" ? 26 : 32, alignment: .top)
                Text(t.all.formatted()).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { if canEdit { personMenu(t, in: group) } }
        .overlay {
            if arranging {
                Menu { personMenu(t, in: group) } label: { Color.clear.contentShape(Rectangle()) }
            }
        }
    }

    // MARK: arranging

    @ViewBuilder private func personMenu(_ t: FacesTag, in group: PeopleGroup?) -> some View {
        if !groups.isEmpty {
            Section("Groups") {
                ForEach(groups) { g in
                    Button { Task { await toggle(t.id, in: g) } } label: {
                        if g.members.contains(t.id) { Label(g.name, systemImage: "checkmark") } else { Text(g.name) }
                    }
                }
            }
        }
        if let g = group, let k = g.members.firstIndex(of: t.id) {
            Section("Order") {
                if k > 0 { Button("Move earlier") { Task { await move(t.id, in: g, by: -1) } } }
                if k < g.members.count - 1 { Button("Move later") { Task { await move(t.id, in: g, by: 1) } } }
            }
        }
        Button { askText = ""; asking = .newGroup(with: t.id) } label: { Label("New group with this person…", systemImage: "plus") }
    }

    private func groupMenu(_ g: PeopleGroup) -> some View {
        let k = groups.firstIndex(where: { $0.id == g.id }) ?? 0
        return Menu {
            Button { askText = g.name; asking = .rename(g) } label: { Label("Rename", systemImage: "pencil") }
            if k > 0 { Button { Task { await reorder(g, by: -1) } } label: { Label("Move up", systemImage: "arrow.up") } }
            if k < groups.count - 1 { Button { Task { await reorder(g, by: 1) } } label: { Label("Move down", systemImage: "arrow.down") } }
            Button(role: .destructive) { deleting = g } label: { Label("Delete group", systemImage: "trash") }
        } label: { Image(systemName: "ellipsis.circle").font(.title3) }
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Sort", selection: $sort) {
                    Text("By group").tag("group"); Text("By family name").tag("family")
                    Text("By name").tag("name"); Text("Most photos first").tag("count")
                }
                if sort == "group" || sort == "family" {
                    Picker("Within each section", selection: $within) {
                        if sort == "group" { Text("As arranged").tag("arranged") }
                        Text("By name").tag("name"); Text("Most photos").tag("count")
                    }
                }
                Picker("Size", selection: $size) {
                    Text("Small").tag("s"); Text("Medium").tag("m"); Text("Large").tag("l")
                }
                Divider()
                Button { openFaces = "unknown" } label: { Label("Faces to name", systemImage: "face.dashed") }
            } label: { Image(systemName: "ellipsis.circle") }
            if canEdit && sort == "group" {
                if arranging {
                    Button { askText = ""; asking = .newGroup(with: nil) } label: { Image(systemName: "plus") }.accessibilityLabel("New group")
                }
                Button(arranging ? "Done" : "Arrange") { arranging.toggle() }
            }
        }
    }

    // MARK: changes (shown at once, put back if the server refuses)

    private func answer(_ ask: Ask?) async {
        let name = askText.trimmingCharacters(in: .whitespaces)
        guard let ask, !name.isEmpty else { return }
        switch ask {
        case .newGroup(let person):
            do {
                let id = try await FacesAPI.createGroup(name)
                var g = PeopleGroup(id: id, name: name, members: [])
                groups.append(g)
                if let person {
                    g.members = [person]
                    groups[groups.count - 1] = g
                    try await FacesAPI.updateGroup(id, members: [person])
                }
                if sort != "group" { sort = "group" }
                arranging = true
            } catch { note = error.localizedDescription; await reloadGroups() }
        case .rename(let g):
            guard name != g.name, let i = groups.firstIndex(where: { $0.id == g.id }) else { return }
            let was = groups
            groups[i].name = name
            do { try await FacesAPI.updateGroup(g.id, name: name) } catch { groups = was; note = error.localizedDescription }
        }
    }

    private func toggle(_ person: Int, in g: PeopleGroup) async {
        guard let i = groups.firstIndex(where: { $0.id == g.id }) else { return }
        let was = groups
        if groups[i].members.contains(person) { groups[i].members.removeAll { $0 == person } } else { groups[i].members.append(person) }
        do { try await FacesAPI.updateGroup(g.id, members: groups[i].members) } catch { groups = was; note = error.localizedDescription }
    }

    private func move(_ person: Int, in g: PeopleGroup, by step: Int) async {
        guard let i = groups.firstIndex(where: { $0.id == g.id }), let k = groups[i].members.firstIndex(of: person) else { return }
        let to = k + step
        guard groups[i].members.indices.contains(to) else { return }
        let was = groups
        groups[i].members.swapAt(k, to)
        do { try await FacesAPI.updateGroup(g.id, members: groups[i].members) } catch { groups = was; note = error.localizedDescription }
    }

    private func reorder(_ g: PeopleGroup, by step: Int) async {
        guard let k = groups.firstIndex(where: { $0.id == g.id }), groups.indices.contains(k + step) else { return }
        let was = groups
        groups.swapAt(k, k + step)
        do { try await FacesAPI.orderGroups(groups.map(\.id)) } catch { groups = was; note = error.localizedDescription }
    }

    private func delete(_ g: PeopleGroup) async {
        let was = groups
        groups.removeAll { $0.id == g.id }
        do { try await FacesAPI.deleteGroup(g.id) } catch { groups = was; note = error.localizedDescription }
    }

    // MARK: loading

    private func load() async {
        async let t: Result<[FacesTag], Error> = { do { return .success(try await FacesAPI.tags()) } catch { return .failure(error) } }()
        async let s = FacesAPI.summary()
        async let g: Void = reloadGroups()
        async let b = loadBirthdays()
        switch await t {
        case .success(let list): tags = list; problem = nil
        case .failure(let e): problem = e.localizedDescription
        }
        summary = await s
        _ = await g
        birthdays = await b
    }

    private func loadBirthdays() async -> [Birthday] {
        guard queue.account?.signedIn == true, let r = try? await IopixClient.shared.json("api/people/birthdays", query: []) else { return [] }
        return (r["upcoming"] as? [[String: Any]] ?? []).prefix(12).compactMap { b in
            guard let t = (b["tag"] as? NSNumber)?.intValue else { return nil }
            return Birthday(id: t, turns: (b["turns"] as? NSNumber)?.intValue, inDays: (b["in"] as? NSNumber)?.intValue ?? 0, date: b["date"] as? String ?? "")
        }
    }

    private func reloadGroups() async {
        let r = await FacesAPI.groups()
        groups = r.groups
        canEdit = r.canEdit && (queue.account?.canWrite ?? false)
    }
}

/// One person: their face and photo count, Then and now when they were photographed years apart, "This is me"
/// for an admin, and all their photos.
struct FacesPersonScreen: View {
    let tag: FacesTag
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var queue: UploadQueue
    @Environment(\.horizontalSizeClass) private var width
    @State private var pair: ThenNowPair?
    @State private var list: PhotoList?
    @State private var viewer: PagerStart?
    @State private var me: Int?
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    FaceImage(person: tag.person).frame(width: 96, height: 96).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tag.name).font(.title2.bold())
                        if let f = tag.family { Text(f).foregroundStyle(.secondary) }
                        Text(tag.all == 1 ? "1 photo" : "\(tag.all.formatted()) photos").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: 10) {
                    Button { router.peoplePath.append(.photos(PhotoQuery([("tag", "\(tag.id)")]), title: tag.name)) } label: {
                        Label("All photos", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { router.peoplePath.append(.photos(PhotoQuery([("tag", "\(tag.id)"), ("sort", "old")]), title: tag.name)) } label: {
                        Label("Oldest first", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)
                    if queue.account?.isAdmin == true {
                        Button { Task { await toggleMe() } } label: {
                            Label(me == tag.id ? "This is me ✓" : "This is me", systemImage: "person.crop.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .font(.subheadline)
                if let p = pair { thenAndNow(p) }
                if let list {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: width == .regular ? 150 : 100), spacing: 3)], spacing: 3) {
                        ForEach(Array(list.ids.prefix(300).enumerated()), id: \.offset) { i, id in
                            Button { viewer = PagerStart(list: list, index: i) } label: {
                                RemoteImage(path: "thumb/\(id)").aspectRatio(1, contentMode: .fill)
                                    .overlay(alignment: .bottomLeading) {
                                        if list.isVideo(i) { Image(systemName: "play.fill").font(.caption2).foregroundStyle(.white).shadow(radius: 2).padding(5) }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if list.ids.count > 300 {
                        Button("See all \(list.ids.count.formatted())") { router.peoplePath.append(.photos(PhotoQuery([("tag", "\(tag.id)")]), title: tag.name)) }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .navigationTitle(tag.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let p = FacesAPI.thenAndNow(tag.id)
            async let l = try? PhotoList.load([URLQueryItem(name: "tag", value: "\(tag.id)"), URLQueryItem(name: "sort", value: "new")])
            async let a = try? IopixClient.shared.account()
            pair = await p
            if let l = await l { list = l } else { list = PhotoList(); note = "The photos couldn't be loaded." }
            me = await a?.person
        }
        .fullScreenCover(item: $viewer) { PhotoPager(start: $0).environmentObject(store).environmentObject(router) }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) { Button("OK", role: .cancel) {} }
    }

    private func thenAndNow(_ p: ThenNowPair) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Then and now").font(.headline)
            HStack(spacing: 12) {
                face(p.then); Image(systemName: "arrow.right").foregroundStyle(.secondary); face(p.now)
                Spacer()
            }
            Text("\(p.years.rounded() == p.years ? String(Int(p.years)) : String(format: "%.1f", p.years)) years apart").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
    }

    private func face(_ f: ThenNowPair.Face) -> some View {
        Button { viewer = PagerStart(list: PhotoList(ids: [f.photo], times: [f.ts]), index: 0) } label: {
            RemoteImage(path: "facecrop/\(f.photo)/" + f.rect.map(String.init).joined(separator: "/") + ".jpg")
                .frame(width: 84, height: 84).clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func toggleMe() async {
        let target: Int? = me == tag.id ? nil : tag.id
        do {
            try await FacesAPI.setMe(target)
            me = target
            note = target == nil ? "Your account is no longer linked to \(tag.name)." : "Your account is now linked to \(tag.name)."
            await queue.refreshAccount()  // Explore's "Photos of me" follows
        } catch { note = error.localizedDescription }
    }
}
