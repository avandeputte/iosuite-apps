import SwiftUI

/// Who is this? People to name a face after: the people in nearby photos of the same folder first, then everyone,
/// with a new person made on the spot when the name typed isn't there.
struct FacesPersonPicker: View {
    var photo: Int?
    let pick: (Int, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [FacesTag] = []
    @State private var near: [Int] = []
    @State private var search = ""
    @State private var creating = false
    @State private var family: Int = 0
    @State private var problem: String?
    @State private var busy = false

    /// People: person tags under People, and single tags filed under a family there that digiKam hasn't marked as
    /// persons yet (naming a face with one marks it).
    private var people: [FacesTag] {
        tags.filter { t in
            let parts = t.full.split(separator: "/")
            return t.full != "People" && parts.first == "People" && (t.isPerson || (!t.hasKids && parts.count > 2))
        }
    }

    private var families: [FacesTag] {
        tags.filter { !$0.isPerson && $0.full.hasPrefix("People/") && $0.full.split(separator: "/").count == 2 }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var hits: [FacesTag] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let rank = { (t: FacesTag) in near.firstIndex(of: t.id) ?? Int.max }
        return people.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.all > $1.all }
            .prefix(60).map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                let typed = search.trimmingCharacters(in: .whitespaces)
                if !typed.isEmpty, !people.contains(where: { $0.name.caseInsensitiveCompare(typed) == .orderedSame }) {
                    Section {
                        Button { creating = true } label: { Label("New person “\(typed)”…", systemImage: "person.badge.plus") }
                    }
                }
                let nearby = hits.filter { near.contains($0.id) }
                if !nearby.isEmpty {
                    Section("In nearby photos of this folder") { ForEach(nearby) { row($0) } }
                }
                Section(nearby.isEmpty ? "" : "Everyone") { ForEach(hits.filter { !near.contains($0.id) }) { row($0) } }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Type a name")
            .navigationTitle("Who is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                tags = (try? await FacesAPI.tags()) ?? []
                if let photo { near = await FacesAPI.nearby(photo) }
            }
            .sheet(isPresented: $creating) { newPerson }
            .alert("Couldn't make the person", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(problem ?? "") }
        }
    }

    private func row(_ t: FacesTag) -> some View {
        Button { dismiss(); pick(t.id, t.name) } label: {
            HStack(spacing: 12) {
                FaceImage(person: t.person).frame(width: 40, height: 40).clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.name).foregroundStyle(.primary)
                    if let f = t.family { Text(f).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(t.all.formatted()).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var newPerson: some View {
        NavigationStack {
            Form {
                Section { Text(search.trimmingCharacters(in: .whitespaces)).font(.headline) }
                Picker("Family", selection: $family) {
                    Text("Directly under People").tag(0)
                    ForEach(families) { Text($0.name).tag($0.id) }
                }
            }
            .navigationTitle("New person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { creating = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let name = search.trimmingCharacters(in: .whitespaces)
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                let id = try await FacesAPI.createPerson(name, family: family == 0 ? nil : family)
                                creating = false
                                dismiss()
                                pick(id, name)
                            } catch {
                                creating = false
                                problem = error.localizedDescription
                            }
                        }
                    }
                    .disabled(busy)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// The faces waiting for a decision: digiKam's suggestions to confirm, unnamed faces (look-alikes together, with
/// iopix's "looks like" guess) and ignored ones. Decide one face or many at once; everything is written by the server.
struct FacesReviewScreen: View {
    @State var tab: String
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var queue: UploadQueue
    @Environment(\.horizontalSizeClass) private var width
    @State private var data: FacesAPI.Queue?
    @State private var alikes: FacesAPI.LookAlikes?
    @State private var problem: String?
    @State private var selected: Set<String> = []
    @State private var picking: ((Int, String) -> Void)?
    @State private var pickPhoto: Int?
    @State private var note: String?
    @State private var confirmRemove: [FaceItem] = []
    @State private var viewer: PagerStart?
    @State private var decided: Set<String> = []
    @AppStorage("faces.grouped") private var grouped = true

    private var canManage: Bool { queue.account?.canWrite == true }
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: width == .regular ? 110 : 84), spacing: 10)] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Faces", selection: $tab) {
                    Text("Suggestions").tag("suggested"); Text("Unnamed").tag("unknown"); Text("Ignored").tag("ignored")
                }
                .pickerStyle(.segmented)
                if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else if let data {
                    content(data)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(16)
        }
        .navigationTitle("Faces")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: tab) { await load() }
        .refreshable { await load() }
        .safeAreaInset(edge: .bottom) { if canManage, !selected.isEmpty, !(tab == "unknown" && showingGroups) { plainBar } }
        .sheet(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } })) {
            FacesPersonPicker(photo: pickPhoto) { id, name in picking?(id, name); picking = nil }
        }
        .confirmationDialog("Remove \(confirmRemove.count == 1 ? "this face region" : "\(confirmRemove.count) face regions")?",
                            isPresented: Binding(get: { !confirmRemove.isEmpty }, set: { if !$0 { confirmRemove = [] } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { let c = confirmRemove; Task { await apply(c.map { $0.op("remove") }, "Removed") } }
        } message: { Text("They are deleted from digiKam's database and the sidecars. There is no undo.") }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) { Button("OK", role: .cancel) {} }
        .fullScreenCover(item: $viewer) { PhotoPager(start: $0).environmentObject(store).environmentObject(router) }
    }

    private var showingGroups: Bool { grouped && alikes?.usable == true }

    // MARK: tabs

    @ViewBuilder private func content(_ d: FacesAPI.Queue) -> some View {
        let faces = d.faces.filter { !decided.contains($0.id) }
        if faces.isEmpty {
            Text(tab == "suggested" ? "No suggestions waiting. digiKam makes suggestions when you run face recognition there."
                 : tab == "unknown" ? "No unnamed faces." : "No ignored faces.")
                .foregroundStyle(.secondary).padding(.top, 40)
        } else if tab == "suggested" {
            Text("\(d.total.formatted()) faces digiKam thinks it recognized, grouped by person. Confirm a whole group, or decide face by face.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(d.groups, id: \.tag) { g in
                let list = faces.filter { $0.tag == g.tag }
                if !list.isEmpty { suggestionGroup(g.tag, g.name, list) }
            }
        } else if tab == "unknown", showingGroups, let a = alikes {
            Text("\(d.total.formatted()) faces digiKam found but couldn't name. Look-alikes are shown together so one decision covers the group; untick a face to leave it out.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Show as a plain grid") { grouped = false }.font(.footnote)
            if a.running { Text("Grouping… \(a.done.formatted()) of \(a.total.formatted()) faces compared.").font(.footnote).foregroundStyle(.orange) }
            else if !a.missing.isEmpty { Text("\(a.missing.count.formatted()) faces haven't been compared yet (the Face grouping job runs in the background).").font(.footnote).foregroundStyle(.orange) }
            if a.people == 0 && !a.running { Text("Suggestions appear once the named people have been compared too.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(Array(a.groups.enumerated()), id: \.offset) { k, g in
                let list = g.faces.filter { !decided.contains($0.id) }
                if !list.isEmpty { block("Look-alikes \(k + 1) · \(list.count) faces", list, suggest: g.suggest, grouped: true) }
            }
            let ung = a.ungrouped.filter { !decided.contains($0.id) }
            if !ung.isEmpty { block("\(ung.count.formatted()) faces without a look-alike", ung, suggest: nil, grouped: false) }
            let mis = a.missing.filter { !decided.contains($0.id) }
            if !mis.isEmpty { block("\(mis.count.formatted()) faces not compared yet", mis, suggest: nil, grouped: false) }
        } else {
            Text(tab == "unknown" ? "\(d.total.formatted()) faces digiKam found but couldn't name. Pick the ones that are the same person and name them together; ignore the ones that aren't faces to name."
                 : "\(d.total.formatted()) faces marked as not to be named.")
                .font(.footnote).foregroundStyle(.secondary)
            if tab == "unknown", alikes?.usable == true { Button("Group look-alikes") { grouped = true }.font(.footnote) }
            if canManage {
                Button(selected.count == faces.count ? "Select none" : "Select all") {
                    selected = selected.count == faces.count ? [] : Set(faces.map(\.id))
                }.font(.subheadline)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(faces) { f in cell(f, selectable: canManage) }
            }
            if d.total > d.faces.count {
                Text("Showing the first \(d.faces.count.formatted()); decide these and the next ones appear.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func cell(_ f: FaceItem, selectable: Bool, sel: Binding<Set<String>>? = nil) -> some View {
        let set = sel ?? $selected
        let on = set.wrappedValue.contains(f.id)
        return FaceCell(face: f, selected: on, selectable: selectable, caption: FaceCell.month(f.ts))
            .onTapGesture {
                if selectable { if on { set.wrappedValue.remove(f.id) } else { set.wrappedValue.insert(f.id) } }
                else { open(f) }
            }
            .contextMenu {
                Button { open(f) } label: { Label("Open the photo", systemImage: "photo") }
                if canManage {
                    Button { name([f]) } label: { Label("Name…", systemImage: "person") }
                    if let s = f.suggest { Button { Task { await apply([f.op("name", tag: s.tag)], "Named \(s.name)") } } label: { Label("Name as \(s.name)", systemImage: "person.fill.checkmark") } }
                    if tab != "ignored" { Button { Task { await apply([f.op("ignore")], "Ignored") } } label: { Label("Ignore", systemImage: "eye.slash") } }
                    else { Button { Task { await apply([f.op("unknown")], "Back to unnamed") } } label: { Label("Back to unnamed", systemImage: "arrow.uturn.backward") } }
                    Button(role: .destructive) { confirmRemove = [f] } label: { Label("Remove face", systemImage: "trash") }
                }
            }
    }

    // MARK: suggestions

    private func suggestionGroup(_ tag: Int, _ name: String, _ faces: [FaceItem]) -> some View {
        GroupBlock(faces: faces, canManage: canManage, columns: columns) { sel in
            HStack(spacing: 10) {
                FaceImage(person: Person(id: tag, name: name, count: 0, face: nil)).frame(width: 36, height: 36).clipShape(Circle())
                VStack(alignment: .leading) {
                    Text(name).font(.headline)
                    Text("\(faces.count) suggested").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if canManage {
                HStack {
                    Button { Task { await apply(chosen(faces, sel).map { $0.op("confirm") }, "Confirmed \(name)") } } label: { Label("Confirm", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent)
                    Button("Reject") { Task { await apply(chosen(faces, sel).map { $0.op("unknown") }, "Rejected") } }.buttonStyle(.bordered)
                    Spacer()
                    Button(sel.wrappedValue.count == faces.count ? "None" : "All") {
                        sel.wrappedValue = sel.wrappedValue.count == faces.count ? [] : Set(faces.map(\.id))
                    }
                }
                .font(.subheadline)
            }
        } cell: { f, sel in cell(f, selectable: canManage, sel: sel) }
    }

    // MARK: look-alikes

    private func block(_ title: String, _ faces: [FaceItem], suggest: FaceSuggestion?, grouped: Bool) -> some View {
        GroupBlock(faces: faces, canManage: canManage, columns: columns) { sel in
            Text(title).font(.headline)
            if grouped, let s = suggest {
                HStack(spacing: 8) {
                    FaceImage(person: Person(id: s.tag, name: s.name, count: 0, face: nil)).frame(width: 28, height: 28).clipShape(Circle())
                    Text("looks like \(s.name) · \(Int((s.score * 100).rounded()))%").font(.subheadline).foregroundStyle(.secondary)
                    if canManage {
                        Button("Name as \(s.name)") { Task { await apply(chosen(faces, sel).map { $0.op("name", tag: s.tag) }, "Named \(s.name)") } }
                            .buttonStyle(.borderedProminent).font(.subheadline)
                    }
                }
            }
            if canManage {
                HStack {
                    Button { name(chosen(faces, sel)) } label: { Label(grouped ? "Name these…" : "Name selected…", systemImage: "person") }
                        .buttonStyle(.bordered)
                    Button("Ignore") { Task { await apply(chosen(faces, sel).map { $0.op("ignore") }, "Ignored") } }.buttonStyle(.bordered)
                    Spacer()
                    Button(sel.wrappedValue.count == faces.count ? "None" : "All") {
                        sel.wrappedValue = sel.wrappedValue.count == faces.count ? [] : Set(faces.map(\.id))
                    }
                }
                .font(.subheadline)
            }
        } cell: { f, sel in
            VStack(spacing: 2) {
                cell(f, selectable: canManage, sel: sel)
                if !grouped, let s = f.suggest {
                    Button(s.name) { Task { await apply([f.op("name", tag: s.tag)], "Named \(s.name)") } }
                        .font(.caption2).lineLimit(1).disabled(!canManage)
                }
            }
        }
    }

    // MARK: plain grid actions

    private var plainBar: some View {
        let faces = (data?.faces ?? []).filter { selected.contains($0.id) }
        return HStack(spacing: 16) {
            Text("\(faces.count) selected").font(.subheadline.weight(.medium))
            Spacer()
            Button { name(faces) } label: { Label("Name", systemImage: "person") }
            if tab == "unknown" { Button("Ignore") { Task { await apply(faces.map { $0.op("ignore") }, "Ignored") } } }
            if tab == "ignored" { Button("Unnamed") { Task { await apply(faces.map { $0.op("unknown") }, "Back to unnamed") } } }
            Button(role: .destructive) { confirmRemove = faces } label: { Image(systemName: "trash") }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: doing

    private func chosen(_ faces: [FaceItem], _ sel: Binding<Set<String>>) -> [FaceItem] { faces.filter { sel.wrappedValue.contains($0.id) } }

    private func name(_ faces: [FaceItem]) {
        guard !faces.isEmpty else { return }
        pickPhoto = faces.first?.photo
        picking = { id, name in Task { await apply(faces.map { $0.op("name", tag: id) }, "Named \(name)") } }
    }

    private func open(_ f: FaceItem) { viewer = PagerStart(list: PhotoList(ids: [f.photo], times: [f.ts]), index: 0) }

    /// Sends the changes; the faces leave the list at once and come back if the server refuses them.
    private func apply(_ ops: [[String: Any]], _ what: String) async {
        guard !ops.isEmpty else { return }
        let keys = Set(ops.compactMap { o -> String? in
            guard let img = o["image"] as? Int, let r = o["rect"] as? [Int], r.count == 4 else { return nil }
            return "\(img):\(r[0]):\(r[1]):\(r[2]):\(r[3])"
        })
        decided.formUnion(keys)
        selected.subtract(keys)
        do {
            let r = try await FacesAPI.batch(ops)
            if r.failed > 0 {
                note = "\(r.failed) of those couldn't be changed\(r.why.map { " (\($0))" } ?? "")."
                await load()
            }
            Task { await store.load() }
        } catch {
            decided.subtract(keys)
            note = "\(what) didn't go through: \(error.localizedDescription)"
        }
    }

    private func load() async {
        problem = nil
        selected = []
        do {
            data = try await FacesAPI.queue(tab)
            decided = []
            if tab == "unknown" { alikes = await FacesAPI.lookAlikes() }
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A block of faces with its own selection (all ticked at first) and its own buttons above the grid.
private struct GroupBlock<Header: View, Cell: View>: View {
    let faces: [FaceItem]
    let canManage: Bool
    let columns: [GridItem]
    @ViewBuilder let header: (Binding<Set<String>>) -> Header
    @ViewBuilder let cell: (FaceItem, Binding<Set<String>>) -> Cell
    @State private var sel: Set<String>?

    var body: some View {
        let binding = Binding<Set<String>>(get: { sel ?? Set(faces.map(\.id)) }, set: { sel = $0 })
        VStack(alignment: .leading, spacing: 10) {
            header(binding)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(faces) { f in cell(f, binding) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
    }
}
