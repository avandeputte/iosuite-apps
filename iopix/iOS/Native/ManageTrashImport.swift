import SwiftUI
import PhotosUI

/// The trash: photos moved there here or in digiKam (each album root's .dtrash folder), to restore or delete for good.
struct ManageTrashScreen: View {
    struct Item: Identifiable, Hashable {
        let info: String
        let name: String
        let path: String
        let when: String
        let size: Int
        let exists: Bool
        var id: String { info }
    }
    @EnvironmentObject private var store: LibraryStore
    @State private var items: [Item] = []
    @State private var bytes = 0
    @State private var loaded = false
    @State private var problem: String?
    @State private var selected: Set<String> = []
    @State private var confirmDelete = false
    @State private var confirmEmpty = false
    @State private var working = false
    @State private var notice: Notice?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 6)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Photos moved to the trash, here or in digiKam, stay with their sidecars until they're restored or deleted for good. Tap photos to select them.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let problem { Text(problem).foregroundStyle(.secondary) }
                if loaded && items.isEmpty && problem == nil {
                    Text("The trash is empty.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 60)
                }
                if !items.isEmpty {
                    Text("\(ManageAPI.plural(items.count, "item")) · \(ManageAPI.bytes(bytes))").font(.subheadline).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(items) { x in
                        Button { if selected.contains(x.info) { selected.remove(x.info) } else { selected.insert(x.info) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                RemoteImage(path: "api/trash/thumb?info=" + (x.info.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))
                                    .aspectRatio(1, contentMode: .fill).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: selected.contains(x.info) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3).foregroundStyle(.white).shadow(radius: 2).padding(5)
                                    }
                                Text(x.name).font(.caption2).lineLimit(1)
                                Text(x.exists ? Self.when(x.when) : "File missing").font(.caption2).foregroundStyle(x.exists ? .secondary : Hue.rose).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Trash")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !items.isEmpty {
                    Button(selected.count == items.count ? "Select none" : "Select all") {
                        selected = selected.count == items.count ? [] : Set(items.map(\.info))
                    }
                    Menu {
                        Button(role: .destructive) { confirmEmpty = true } label: { Label("Empty the trash…", systemImage: "trash.slash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selected.isEmpty {
                HStack(spacing: 20) {
                    Text("\(selected.count) selected").font(.subheadline)
                    Spacer()
                    Button { Task { await restore() } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                }
                .disabled(working)
                .padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
            }
        }
        .overlay { if working { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Delete \(ManageAPI.plural(selected.count, "photo")) for good?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete for good", role: .destructive) { Task { await empty(Array(selected)) } }
        } message: { Text("They can't be brought back.") }
        .confirmationDialog("Empty the whole trash?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Delete everything in the trash", role: .destructive) { Task { await empty(nil) } }
        } message: { Text("\(ManageAPI.plural(items.count, "item")) are deleted for good. They can't be brought back.") }
        .notice($notice)
    }

    private func load() async {
        do {
            let j = try await ManageAPI.get("api/trash")
            items = (j["items"] as? [[String: Any]] ?? []).compactMap { i in
                guard let info = i["info"] as? String else { return nil }
                return Item(info: info, name: i["name"] as? String ?? "", path: i["path"] as? String ?? "", when: i["when"] as? String ?? "",
                            size: (i["size"] as? NSNumber)?.intValue ?? 0, exists: i["exists"] as? Bool ?? true)
            }
            bytes = (j["bytes"] as? NSNumber)?.intValue ?? 0
            selected = selected.intersection(items.map(\.info))
            problem = nil
        } catch IopixError.needsSignIn {
            problem = "Sign in as an editor to see the trash."
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    private func restore() async {
        working = true
        defer { working = false }
        do {
            let r = try await ManageAPI.post("api/trash/restore", ["infos": Array(selected)])
            let ok = (r["restored"] as? [Any])?.count ?? 0, failed = (r["failed"] as? [[String: Any]]) ?? []
            notice = Notice(text: "\(ManageAPI.plural(ok, "photo")) restored" + (failed.isEmpty ? "." : ", \(failed.count) not: \(failed.first?["error"] as? String ?? "")"),
                            failed: ok == 0 && !failed.isEmpty)
            selected = []
            await load()
            await store.load()
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }

    private func empty(_ infos: [String]?) async {
        working = true
        defer { working = false }
        do {
            let body: [String: Any] = infos.map { ["infos": $0] } ?? ["all": true]
            let r = try await ManageAPI.post("api/trash/empty", body)
            notice = Notice(text: "\(ManageAPI.plural((r["deleted"] as? NSNumber)?.intValue ?? 0, "item")) deleted for good.")
            selected = []
            await load()
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }

    /// The trash records' times are ISO dates; shown as a short date.
    private static func when(_ s: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        if let d = f.date(from: String(s.prefix(19))) ?? ISO8601DateFormatter().date(from: s) {
            return d.formatted(date: .abbreviated, time: .shortened)
        }
        return s.replacingOccurrences(of: "T", with: " ")
    }
}

/// Import as the web app's Import page does: pick photos, see where each would go (and which are already in the
/// library), choose the folder layout and what to do with duplicates, then import.
struct ManageImportScreen: View {
    struct Planned: Identifiable, Hashable {
        let name: String
        let size: Int
        let when: String?
        let folder: String?
        let duplicate: Int?
        let kind: String
        let error: String?
        var id: String { name }
    }
    struct Layout: Identifiable, Hashable { let key: String, example: String; var id: String { key } }

    @EnvironmentObject private var store: LibraryStore
    @StateObject private var rights = ManageRights()
    @State private var picked: [PhotosPickerItem] = []
    @State private var token: String?
    @State private var plan: [Planned] = []
    @State private var layouts: [Layout] = []
    @State private var layout = ""
    /// An admin's layout choice becomes the server's default (the web app's "Remember as the default layout").
    @State private var remember = true
    @State private var importDuplicates = false
    #if !targetEnvironment(macCatalyst)
    @State private var camera = false
    #endif
    @State private var skip: Set<String> = []
    @State private var working: String?
    @State private var confirmDiscard = false
    @State private var notice: Notice?
    @State private var done: (added: Int, skipped: [String])?

    var body: some View {
        List {
            Section {
                PhotosPicker(selection: $picked, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                    Label(token == nil ? "Choose photos and videos" : "Add more", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(working != nil)
                #if !targetEnvironment(macCatalyst)
                // the camera: on an iPhone or iPad (a Mac has none)
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { camera = true } label: { Label("Take a photo", systemImage: "camera") }.disabled(working != nil)
                }
                #endif
            } footer: {
                Text("Nothing goes into the library until you choose Import. Files are kept aside on the server for two days.")
            }
            if let done {
                Section("Imported") {
                    Text("\(ManageAPI.plural(done.added, "file")) added to the library.")
                    ForEach(done.skipped, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            if !plan.isEmpty {
                Section("Choices") {
                    if !layouts.isEmpty {
                        Picker("Folders", selection: $layout) {
                            ForEach(layouts) { Text($0.example).tag($0.key) }
                        }
                    }
                    if rights.isAdmin && !layouts.isEmpty { Toggle("Remember as the default layout", isOn: $remember) }
                    Toggle("Import duplicates too", isOn: $importDuplicates)
                }
                let new = plan.filter { $0.duplicate == nil && $0.error == nil }.count
                let dups = plan.filter { $0.duplicate != nil }.count
                Section {
                    ForEach(plan) { p in
                        HStack(alignment: .top) {
                            Image(systemName: p.kind == "video" ? "video" : "photo").foregroundStyle(.secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).lineLimit(1)
                                Group {
                                    if let e = p.error { Text(e).foregroundStyle(Hue.rose) }
                                    else if p.duplicate != nil { Text("Already in the library" + (importDuplicates ? " · imported anyway" : " · skipped")) }
                                    else { Text([p.folder, ManageAPI.bytes(p.size)].compactMap { $0 }.joined(separator: " · ")) }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if p.error == nil && (p.duplicate == nil || importDuplicates) {
                                Toggle("", isOn: Binding(get: { !skip.contains(p.name) }, set: { on in if on { skip.remove(p.name) } else { skip.insert(p.name) } }))
                                    .labelsHidden()
                            }
                        }
                    }
                } header: {
                    Text("\(ManageAPI.plural(plan.count, "file")) · \(new) new" + (dups > 0 ? " · \(dups) already there" : ""))
                }
                Section {
                    Button { Task { await run() } } label: { Label("Import", systemImage: "square.and.arrow.down") }
                        .disabled(working != nil || plan.allSatisfy { $0.error != nil || ($0.duplicate != nil && !importDuplicates) || skip.contains($0.name) })
                    Button("Discard", role: .destructive) { confirmDiscard = true }.disabled(working != nil)
                }
            }
        }
        .overlay { if let w = working { ProgressView(w).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .navigationTitle("Import")
        .task { await rights.load(); await loadLayouts() }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                working = "Getting your photos…"
                let files = await ManageAPI.files(from: items)
                await stage(files: files)
            }
        }
        #if !targetEnvironment(macCatalyst)
        .fullScreenCover(isPresented: $camera) {
            CameraPicker { url in if let url { Task { await stage(files: [url]) } } }.ignoresSafeArea()
        }
        #endif
        .onChange(of: layout) { _, _ in Task { await replan() } }
        .confirmationDialog("Discard the staged photos?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { Task { await discard() } }
        } message: { Text("They are removed from the server; nothing has reached the library.") }
        .notice($notice)
    }

    private func loadLayouts() async {
        guard layouts.isEmpty, let j = try? await ManageAPI.get("api/import/layouts") else { return }
        layouts = (j["layouts"] as? [[String: Any]] ?? []).compactMap { l in
            guard let k = l["key"] as? String else { return nil }
            return Layout(key: k, example: l["example"] as? String ?? k)
        }
        if layout.isEmpty { layout = j["layout"] as? String ?? layouts.first?.key ?? "" }
    }

    /// Sends files from this device (the photo library, or the camera) to the server's staging area.
    private func stage(files: [URL]) async {
        defer { working = nil }
        done = nil
        defer { ManageAPI.cleanUp(files) }
        guard !files.isEmpty else { notice = Notice(text: "Couldn't read the photos picked.", failed: true); return }
        working = "Sending \(ManageAPI.plural(files.count, "file"))…"
        do {
            var fields = ["layout": layout]
            if let token { fields["token"] = token }
            let r = try await ManageAPI.upload("api/import/stage", files: files, fields: fields)
            read(r)
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }

    private func replan() async {
        guard let token else { return }
        if let r = try? await ManageAPI.get("api/import/\(token)", [URLQueryItem(name: "layout", value: layout)]) { read(r) }
    }

    private func read(_ r: [String: Any]) {
        token = r["token"] as? String ?? token
        plan = (r["items"] as? [[String: Any]] ?? []).map { i in
            Planned(name: i["name"] as? String ?? "", size: (i["size"] as? NSNumber)?.intValue ?? 0, when: i["when"] as? String,
                    folder: i["folder"] as? String, duplicate: (i["duplicate_of"] as? NSNumber)?.intValue, kind: i["kind"] as? String ?? "photo",
                    error: i["error"] as? String)
        }
    }

    private func run() async {
        guard let token else { return }
        working = "Importing…"
        defer { working = nil }
        let include = plan.filter { $0.error == nil && ($0.duplicate == nil || importDuplicates) && !skip.contains($0.name) }.map(\.name)
        do {
            let r = try await ManageAPI.post("api/import/\(token)/run", ["layout": layout, "include": include, "duplicates": importDuplicates ? "import" : "skip",
                                                                          "remember": rights.isAdmin && remember])
            let added = (r["added"] as? [Any])?.count ?? 0
            let skipped = (r["skipped"] as? [[String: Any]] ?? []).map { "\($0["name"] as? String ?? ""): \($0["reason"] as? String ?? "skipped")" }
            done = (added, skipped)
            self.token = nil
            plan = []
            skip = []
            await store.load()
        } catch {
            notice = Notice(text: error.localizedDescription, failed: true)
        }
    }

    private func discard() async {
        if let token { _ = try? await ManageAPI.post("api/import/\(token)/discard") }
        token = nil
        plan = []
        skip = []
    }
}

#if !targetEnvironment(macCatalyst)
/// The camera, for one photo (or video) to import: the capture is written to its own temporary folder, which
/// `ManageAPI.cleanUp` removes once sent. Nil when the person cancelled.
struct CameraPicker: UIViewControllerRepresentable {
    let taken: (URL?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.mediaTypes = ["public.image", "public.movie"]
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let owner: CameraPicker
        init(_ owner: CameraPicker) { self.owner = owner }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            owner.dismiss()
            owner.taken(nil)
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            owner.dismiss()
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd_HHmmss"
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let movie = info[.mediaURL] as? URL {
                    let url = dir.appendingPathComponent("VID_\(f.string(from: Date())).\(movie.pathExtension.isEmpty ? "mov" : movie.pathExtension)")
                    try FileManager.default.copyItem(at: movie, to: url)
                    owner.taken(url)
                } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.92) {
                    let url = dir.appendingPathComponent("IMG_\(f.string(from: Date())).jpg")
                    try data.write(to: url)
                    owner.taken(url)
                } else {
                    owner.taken(nil)
                }
            } catch {
                owner.taken(nil)
            }
        }
    }
}
#endif
