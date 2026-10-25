import SwiftUI

/// What the editing screen reports back to the viewer.
enum EditOutcome {
    case changed        // the details changed (title, tags, faces...): reload what is shown
    case pictureChanged // the picture itself changed (rotated, cropped): its thumbnail and preview are new
    case removed        // moved to the trash: leave it out of the list
    case added(Int)     // a new version was saved (adjustments): its id
}

/// Editing one photo, as in the web app's viewer and its editing panel: title, caption, rating, pick and colour
/// labels, date taken, keywords and location (saved together), and the tools: faces, rotate or flip, crop,
/// adjustments, rename, move, trash, undo edits, the photo's edit log and all of its metadata.
/// Shown only to accounts that can change the library (editors and admins).
struct PhotoEditSheet: View {
    let photo: Int
    var onOutcome: (EditOutcome) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = EditCatalog.shared
    @ObservedObject private var rights = EditRights.shared
    @State private var original: EditDetail?
    @State private var draft = EditDetail()
    @State private var problem: String?
    @State private var saving = false
    @State private var toast: String?
    @State private var tagPicker = false
    @State private var location = false
    @State private var faces = false
    @State private var crop = false
    @State private var adjust = false
    @State private var history = false
    @State private var metadata = false
    @State private var moving = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmTrash = false
    @State private var confirmRevert = false
    @State private var busy: String?

    private var changes: [String: Any] {
        guard let o = original else { return [:] }
        var c: [String: Any] = [:]
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines) != o.title { c["title"] = draft.title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if draft.caption.trimmingCharacters(in: .whitespacesAndNewlines) != o.caption { c["caption"] = draft.caption.trimmingCharacters(in: .whitespacesAndNewlines) }
        if draft.rating != o.rating { c["rating"] = draft.rating }
        if draft.pick != o.pick { c["pick"] = draft.pick }
        if draft.color != o.color { c["color"] = draft.color }
        if let t = draft.taken, t != o.taken { c["taken"] = EditAPI.takenString(t) }
        let before = Set(o.keywords.map(\.id)), after = Set(draft.keywords.map(\.id))
        if !after.subtracting(before).isEmpty { c["add_tags"] = Array(after.subtracting(before)) }
        if !before.subtracting(after).isEmpty { c["remove_tags"] = Array(before.subtracting(after)) }
        if draft.lat != o.lat || draft.lon != o.lon {
            if let la = draft.lat, let lo = draft.lon { c["gps"] = ["lat": la, "lon": lo, "alt": draft.alt as Any? ?? NSNull()] }
            else { c["gps"] = NSNull() }
        }
        return c
    }

    var body: some View {
        NavigationStack {
            Group {
                if original != nil {
                    form
                } else if let problem {
                    VStack(spacing: 12) {
                        Text("Couldn't load this photo").font(.headline)
                        Text(problem).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try again") { Task { await load() } }.buttonStyle(.borderedProminent)
                    }
                    .padding(32)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(original?.name ?? "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Save") { Task { await save() } }.disabled(changes.isEmpty)
                    }
                }
            }
            .editToast($toast)
        }
        .task { await rights.refresh(); await catalog.load(); await load() }
        .sheet(isPresented: $tagPicker) {
            EditTagPicker(chosen: Set(draft.keywords.map(\.id))) { entry in
                if !draft.tags.contains(where: { $0.id == entry.id }) {
                    draft.tags.append(EditDetail.Tag(id: entry.id, name: entry.name, full: entry.full, person: false))
                }
            }
        }
        .sheet(isPresented: $location) {
            EditLocationSheet(photo: photo, lat: draft.lat, lon: draft.lon) { la, lo, alt in
                draft.lat = la; draft.lon = lo; draft.alt = alt
            }
        }
        .fullScreenCover(isPresented: $faces, onDismiss: { Task { await load(keepDraft: true) } }) {
            EditFacesView(photo: photo) { onOutcome(.changed) }
        }
        .fullScreenCover(isPresented: $crop) {
            if let o = original {
                EditCropView(detail: o) { onOutcome(.pictureChanged); Task { await load() }; toast = "Cropped. The original is kept for Undo." }
            }
        }
        .fullScreenCover(isPresented: $adjust) {
            if let o = original {
                EditAdjustView(detail: o) { id, name in onOutcome(.added(id)); toast = "Saved as \(name), next to the original." }
            }
        }
        .sheet(isPresented: $history) { EditHistoryView(photo: photo) { onOutcome(.pictureChanged); Task { await load() } } }
        .sheet(isPresented: $metadata) { EditMetadataView(photo: photo) { onOutcome(.changed); Task { await load() } } }
        .sheet(isPresented: $moving) {
            EditFolderPicker(current: original?.folderID) { folder in Task { await move(to: folder) } }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("New name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await rename() } }
        } message: { Text("The extension stays as it is.") }
        .confirmationDialog("Move this photo to the trash?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { Task { await trash() } }
        } message: { Text("It can be restored from the trash in iopix.") }
        .confirmationDialog("Undo the edits iopix made to this photo?", isPresented: $confirmRevert, titleVisibility: .visible) {
            Button("Undo edits", role: .destructive) { Task { await revert() } }
        } message: { Text("Its sidecar goes back to how it was before iopix first changed it.") }
    }

    // MARK: the form

    private var form: some View {
        Form {
            if !rights.canWrite {
                Section { Text("This account can look but not change photos. Ask an admin for editor rights.").font(.footnote).foregroundStyle(.secondary) }
            }
            Section("Title and caption") {
                TextField("Title", text: $draft.title)
                TextField("Caption", text: $draft.caption, axis: .vertical).lineLimit(2...8)
            }
            Section("Rating and labels") {
                HStack(spacing: 14) {
                    ForEach(1...5, id: \.self) { n in
                        Button { draft.rating = draft.rating == n ? 0 : n } label: {
                            Image(systemName: n <= draft.rating ? "star.fill" : "star").font(.title3)
                                .foregroundStyle(n <= draft.rating ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(n) star\(n == 1 ? "" : "s")")
                    }
                    Spacer()
                    if draft.rating > 0 { Button("Clear") { draft.rating = 0 }.font(.footnote) }
                }
                Picker("Pick label", selection: $draft.pick) {
                    Text("None").tag(0); Text("Rejected").tag(1); Text("Pending").tag(2); Text("Accepted").tag(3)
                }
                Picker("Color label", selection: $draft.color) {
                    ForEach(Array(Self.colors.enumerated()), id: \.offset) { i, c in
                        HStack { Circle().fill(c.1).frame(width: 12, height: 12); Text(c.0) }.tag(i)
                    }
                }
            }
            Section("Date taken") {
                DatePicker("Taken", selection: Binding(get: { draft.taken ?? Date() }, set: { draft.taken = $0 }),
                           displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                if draft.taken == nil { Text("No date yet: pick one to set it.").font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                ForEach(draft.keywords) { t in
                    HStack {
                        Label(t.name, systemImage: "tag")
                        Spacer()
                        Text(t.full.split(separator: "/").dropLast().joined(separator: " › ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .swipeActions { Button("Remove", role: .destructive) { draft.tags.removeAll { $0.id == t.id } } }
                }
                if !recentChoices.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(recentChoices) { e in
                                Button {
                                    draft.tags.append(EditDetail.Tag(id: e.id, name: e.name, full: e.full, person: false))
                                } label: {
                                    Label(e.name, systemImage: "plus").font(.caption)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Hue.orange.opacity(0.14), in: Capsule()).foregroundStyle(Hue.orange)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Button { tagPicker = true } label: { Label("Add a tag…", systemImage: "plus.circle") }
            } header: { Text("Tags") } footer: {
                if !draft.people.isEmpty { Text("People: \(draft.people.map(\.name).joined(separator: ", ")). Change them under Faces.") }
            }
            Section("Location") {
                if let la = draft.lat, let lo = draft.lon {
                    LabeledContent("Position", value: String(format: "%.5f, %.5f", la, lo))
                    if let p = original?.place, draft.lat == original?.lat { Text(p).font(.footnote).foregroundStyle(.secondary) }
                } else {
                    Text("No location").foregroundStyle(.secondary)
                }
                Button { location = true } label: { Label(draft.lat == nil ? "Set the location…" : "Change the location…", systemImage: "mappin.and.ellipse") }
                if draft.lat != nil {
                    Button(role: .destructive) { draft.lat = nil; draft.lon = nil; draft.alt = nil } label: { Label("Remove the location", systemImage: "mappin.slash") }
                }
            }
            Section("Tools") {
                tool("Faces and people…", "person.crop.square") { faces = true }
                Menu {
                    Button { Task { await transform("left") } } label: { Label("Rotate left", systemImage: "rotate.left") }
                    Button { Task { await transform("right") } } label: { Label("Rotate right", systemImage: "rotate.right") }
                    Button { Task { await transform("180") } } label: { Label("Turn upside down", systemImage: "arrow.2.circlepath") }
                    Button { Task { await transform("fliph") } } label: { Label("Flip left to right", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    Button { Task { await transform("flipv") } } label: { Label("Flip top to bottom", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                } label: { Label("Rotate or flip", systemImage: "rotate.right") }
                if original?.video == false {
                    tool("Crop…", "crop") { crop = true }
                    tool("Adjust (new version)…", "slider.horizontal.3") { adjust = true }
                }
                tool("Rename…", "character.cursor.ibeam") { newName = (original?.name as NSString?)?.deletingPathExtension ?? ""; renaming = true }
                tool("Move to another folder…", "folder") { moving = true }
                if let folder = original?.folderID, original?.video == false {
                    tool("Use as the folder's cover", "photo.on.rectangle") { Task { await folderCover(folder) } }
                }
                tool("Look for faces", "viewfinder") { Task { await detectFaces() } }
                tool("Edit log…", "clock.arrow.circlepath") { history = true }
                tool("All metadata…", "list.bullet.rectangle") { metadata = true }
                if original?.edited == true {
                    Button(role: .destructive) { confirmRevert = true } label: { Label("Undo iopix's edits", systemImage: "arrow.uturn.backward") }
                }
                Button(role: .destructive) { confirmTrash = true } label: { Label("Move to Trash", systemImage: "trash") }
            }
            .disabled(!rights.canWrite || busy != nil)
            if let busy {
                Section { HStack { ProgressView(); Text(busy).foregroundStyle(.secondary) } }
            }
        }
        .disabled(saving)
    }

    private func tool(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
    }

    private var recentChoices: [EditCatalog.Entry] {
        let have = Set(draft.keywords.map(\.id))
        return catalog.recent.compactMap { catalog.tag($0) }.filter { !have.contains($0.id) }.prefix(8).map { $0 }
    }

    static let colors: [(String, Color)] = [
        ("None", .clear), ("Red", .red), ("Orange", .orange), ("Yellow", .yellow), ("Green", .green),
        ("Blue", .blue), ("Magenta", .pink), ("Gray", .gray), ("Black", .black), ("White", .white)]

    // MARK: actions

    private func load(keepDraft: Bool = false) async {
        do {
            let d = try await EditAPI.detail(photo)
            let unsaved = keepDraft ? changes : [:]
            original = d
            if unsaved.isEmpty { draft = d } else { draft.faces = d.faces; draft.tags = draft.keywords + d.people }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func save() async {
        let c = changes
        guard !c.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            try await EditAPI.edit([photo], c)
            if let added = c["add_tags"] as? [Int] { await catalog.noteRecent(added) }
            onOutcome(.changed)
            await load()
            toast = "Saved."
        } catch {
            toast = "Not saved: \(error.localizedDescription)"
        }
    }

    private func run(_ label: String, _ work: () async throws -> String?) async {
        busy = label
        defer { busy = nil }
        do {
            if let note = try await work() { toast = note }
        } catch {
            toast = error.localizedDescription
        }
    }

    private func transform(_ op: String) async {
        await run("Turning…") {
            try await EditAPI.post("api/photos/transform", ["ids": [photo], "op": op])
            onOutcome(.pictureChanged)
            await load(keepDraft: true)
            return "Done. Undo is in the edit log."
        }
    }

    private func rename() async {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        await run("Renaming…") {
            let r = try await EditAPI.post("api/photos/rename", ["id": photo, "name": n])
            if let f = (r["failed"] as? [[String: Any]])?.first { throw EditAPI.Failure(message: f["error"] as? String ?? "Not renamed.") }
            onOutcome(.changed)
            await load(keepDraft: true)
            return "Renamed."
        }
    }

    private func move(to folder: EditCatalog.Entry) async {
        await run("Moving…") {
            let r = try await EditAPI.post("api/photos/move", ["ids": [photo], "album": folder.id])
            if let f = (r["failed"] as? [[String: Any]])?.first { throw EditAPI.Failure(message: f["error"] as? String ?? "Not moved.") }
            onOutcome(.changed)
            await load(keepDraft: true)
            return "Moved to \(folder.full)."
        }
    }

    private func trash() async {
        await run("Moving to the trash…") {
            let r = try await EditAPI.post("api/photos/trash", ["ids": [photo]])
            if let f = (r["failed"] as? [[String: Any]])?.first { throw EditAPI.Failure(message: f["error"] as? String ?? "Not moved to the trash.") }
            onOutcome(.removed)
            dismiss()
            return nil
        }
    }

    private func revert() async {
        await run("Undoing…") {
            try await EditAPI.post("api/edit/revert", ["ids": [photo]])
            onOutcome(.changed)
            await load()
            return "Edits undone; the sidecar is back as it was."
        }
    }

    private func folderCover(_ folder: Int) async {
        await run("Setting the cover…") {
            try await EditAPI.post("api/folders/\(folder)/properties", ["icon": photo])
            return "Now the cover of \(original?.folderName ?? "its folder")."
        }
    }

    private func detectFaces() async {
        await run("Looking for faces…") {
            let r = try await EditAPI.post("api/faces/detect", ["ids": [photo]])
            let added = (r["added"] as? NSNumber)?.intValue ?? (r["added"] as? [Any])?.count ?? 0
            await load(keepDraft: true)
            onOutcome(.changed)
            return added > 0 ? "Found \(added) new face\(added == 1 ? "" : "s"). Name them under Faces." : "No new faces found."
        }
    }
}

// MARK: - Tags

/// Choosing a keyword tag: search the library's tags, or make a new one (under the tag chosen as its parent).
struct EditTagPicker: View {
    let chosen: Set<Int>
    let pick: (EditCatalog.Entry) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = EditCatalog.shared
    @State private var search = ""
    @State private var parent: Int?
    @State private var making = false
    @State private var problem: String?

    private var matches: [EditCatalog.Entry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let list = catalog.tags.filter { !chosen.contains($0.id) }
        return q.isEmpty ? list : list.filter { $0.full.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                let q = search.trimmingCharacters(in: .whitespaces)
                if !q.isEmpty, !catalog.tags.contains(where: { $0.name.caseInsensitiveCompare(q) == .orderedSame }) {
                    Section {
                        Picker("Inside", selection: $parent) {
                            Text("At the top").tag(Int?.none)
                            ForEach(catalog.tags.filter { t in t.parent == nil || catalog.tags.contains(where: { c in c.parent == t.id }) }) { t in
                                Text(t.full).tag(Int?.some(t.id))
                            }
                        }
                        Button { Task { await make(q) } } label: {
                            if making { ProgressView() } else { Label("New tag “\(q)”", systemImage: "plus") }
                        }
                        .disabled(making)
                        if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                    }
                }
                Section {
                    ForEach(matches.prefix(300)) { t in
                        Button { pick(t); dismiss() } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).foregroundStyle(.primary)
                                if t.full != t.name { Text(t.full).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find or make a tag")
            .navigationTitle("Add a tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await catalog.load() }
        }
    }

    private func make(_ name: String) async {
        making = true
        defer { making = false }
        do {
            var op: [String: Any] = ["op": "add", "name": name]
            op["parent"] = parent ?? 0
            let r = try await EditAPI.post("api/tags/op", op)
            await catalog.load(force: true)
            let id = (r["id"] as? NSNumber)?.intValue
            // the library summary may take a moment to list the new tag: its id is enough to add it
            if let e = (id.flatMap { catalog.tag($0) }) ?? id.map({ EditCatalog.Entry(id: $0, name: name, full: name, parent: parent, count: 0) }) {
                pick(e)
                dismiss()
            } else {
                problem = "Made, but it can't be found yet. Try again in a moment."
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - Folders

/// Choosing a folder to move photos into.
struct EditFolderPicker: View {
    let current: Int?
    let pick: (EditCatalog.Entry) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = EditCatalog.shared
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List(catalog.folders.filter { $0.id != current && (search.isEmpty || $0.full.localizedCaseInsensitiveContains(search)) }.prefix(400)) { f in
                Button { pick(f); dismiss() } label: {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Hue.teal)
                        Text(f.full).foregroundStyle(.primary).lineLimit(2)
                        Spacer()
                        Text(f.count.formatted()).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a folder")
            .navigationTitle("Move to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await catalog.load() }
        }
    }
}
