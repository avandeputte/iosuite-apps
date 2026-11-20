import PhotosUI
import SwiftUI

struct NotesList: View {
    @EnvironmentObject private var store: NotesStore
    @Binding var selection: Note.ID?
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        List(selection: $selection) {
            ForEach(store.notes) { note in
                NoteRow(note: note)
                    .tag(note.id)
                    .swipeActions(edge: .trailing) {
                        if store.canChange(note) {
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(note) }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if store.canChange(note) {
                            Button(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin") { store.togglePin(note) }
                                .tint(Brand.gold)
                        }
                    }
                    .contextMenu {
                        NoteActions(note: note) { delete(note) }
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if store.notes.isEmpty {
                if !store.searchText.isEmpty {
                    ContentUnavailableView.search(text: store.searchText)
                } else if store.selectedTag != nil {
                    ContentUnavailableView("No notes with this tag", systemImage: "number")
                } else if store.familyOnly {
                    ContentUnavailableView("No family notes yet", systemImage: "person.2",
                                           description: Text("A note made here is everyone's to read: the wifi password, the bin days, the packing list."))
                } else {
                    ContentUnavailableView("No notes yet", systemImage: "note.text",
                                           description: Text("Write one, paste what you copied, or add photos and screenshots. Notes you save on your Mac show up here too."))
                }
            }
        }
        .searchable(text: $store.searchText, prompt: "Search notes")
        .navigationTitle(!store.searchText.isEmpty ? "Search"
                         : store.selectedTag.map { "#\($0)" } ?? store.folderName(store.selectedFolder) ?? (store.familyOnly ? "Family" : "All Notes"))
        .refreshable { await store.sync() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $store.sort) {
                        ForEach(NoteSort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    TemplateMenuItems { note in
                        store.searchText = ""
                        selection = note.id
                    }
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                } primaryAction: {
                    newNote()
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .images) {
                    Label("Add Photos", systemImage: "photo.badge.plus")
                }
                Spacer()
                Text(countText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                // The system Paste button: iOS doesn't ask for permission each time you use it.
                PasteButton(supportedContentTypes: [.image, .plainText, .url]) { providers in
                    Task { @MainActor in
                        if let note = await store.addPasted(providers, inFolder: store.selectedFolder, family: store.familyOnly) { selection = note.id }
                    }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
            }
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task {
                if let note = await store.addPhotos(items, inFolder: store.selectedFolder, family: store.familyOnly) { selection = note.id }
            }
        }
    }

    private var countText: String {
        store.notes.count == 1 ? "1 note" : "\(store.notes.count) notes"
    }

    private func newNote() {
        if let note = store.createBlankNote() {
            store.searchText = ""
            selection = note.id
        }
    }

    private func delete(_ note: Note) {
        guard store.canChange(note) else { return }
        if selection == note.id { selection = nil }
        store.deleteNote(note)
    }
}

/// Copy, share, pin, file, tag and delete: the long-press menu on a note and the editor's "…" menu.
struct NoteActions: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note
    let onDelete: () -> Void

    var body: some View {
        Button("Copy", systemImage: "doc.on.doc") { store.copyToPasteboard(note) }
        if note.hasImage {
            ShareLink(item: NoteImage(note: note), preview: SharePreview(note.displayTitle)) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        } else {
            ShareLink(item: note.body.isEmpty ? note.displayTitle : note.body) { Label("Share…", systemImage: "square.and.arrow.up") }
        }
        let mine = store.canChange(note)
        if mine {
            Button(note.pinned ? "Unpin" : "Pin to Top", systemImage: note.pinned ? "pin.slash" : "pin") { store.togglePin(note) }
            FolderMenu(note: note)
        }
        if !store.tags.isEmpty, mine {
            Menu {
                ForEach(store.tags) { tag in
                    let has = note.tags.contains { $0.caseInsensitiveCompare(tag.name) == .orderedSame }
                    Button {
                        store.setTags(has ? note.tags.filter { $0.caseInsensitiveCompare(tag.name) != .orderedSame }
                                          : note.tags + [tag.name], for: note.id)
                    } label: {
                        if has { Label(tag.name, systemImage: "checkmark") } else { Text(tag.name) }
                    }
                }
            } label: {
                Label("Tags", systemImage: "number")
            }
        }
        if mine {
            Divider()
            Button("Delete Note", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

struct NoteRow: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if note.hasImage {
                Thumbnail(noteID: note.id, version: note.imageKey, size: 52)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if note.pinned {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(Brand.gold)
                    }
                    Text(note.displayTitle)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Image(systemName: NoteRow.icon(for: note.source))
                    Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if note.family, !store.familyOnly {
                        Image(systemName: "person.2.fill").foregroundStyle(Brand.teal).accessibilityLabel("Family note")
                    }
                    ForEach(note.tags.prefix(3), id: \.self) { TagChip(name: $0) }
                    NoteBadges(note: note)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    static func icon(for source: String) -> String {
        switch source {
        case "screenshot": return "camera.viewfinder"
        case "photo": return "photo"
        case "service": return "cursorarrow.click.2"
        case "clipboard": return "doc.on.clipboard"
        default: return "square.and.pencil"
        }
    }
}

/// "Move to Folder ▸ No Folder / Work / AI", and for an editor or an admin "Family": the space everyone reads.
/// Picking a folder for a family note makes it one's own again.
struct FolderMenu: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note
    var title = "Move to Folder"

    var body: some View {
        Menu {
            Button {
                move(to: nil)
            } label: {
                if note.folderID == nil, !note.family { Label("No Folder", systemImage: "checkmark") } else { Text("No Folder") }
            }
            ForEach(store.folders) { folder in
                Button {
                    move(to: folder.id)
                } label: {
                    if note.folderID == folder.id { Label(folder.name, systemImage: "checkmark") } else { Text(folder.name) }
                }
            }
            if store.familyWrite {
                Divider()
                Button {
                    store.setFamily(true, for: note.id)
                } label: {
                    if note.family { Label("Family", systemImage: "checkmark") } else { Label("Family", systemImage: "person.2") }
                }
            }
        } label: {
            Label(title, systemImage: note.family ? "person.2" : "folder")
        }
    }

    private func move(to folderID: String?) {
        if note.family {
            store.setFamily(false, for: note.id, folder: folderID)
        } else {
            store.moveNote(id: note.id, toFolder: folderID)
        }
    }
}

struct TagChip: View {
    @EnvironmentObject private var store: NotesStore
    let name: String

    var body: some View {
        let color = store.tagColor(name)?.color
        Text("#" + name)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background((color ?? Brand.teal).opacity(color == nil ? 0.15 : 0.25), in: Capsule())
            .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
    }
}

/// "Color ▸ None / Red / Orange …" for folders and tags.
struct ColorMenu: View {
    let selected: LabelColor?
    let pick: (LabelColor?) -> Void

    var body: some View {
        Menu {
            Button {
                pick(nil)
            } label: {
                if selected == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
            }
            ForEach(LabelColor.allCases) { color in
                Button {
                    pick(color)
                } label: {
                    // Menus draw symbols without colour, so use a swatch that keeps its own.
                    Label { Text(color == selected ? "\(color.title) ✓" : color.title) } icon: { Image(uiImage: color.swatch) }
                }
            }
        } label: {
            Label("Color", systemImage: "paintpalette")
        }
    }
}

extension LabelColor {
    var swatch: UIImage {
        let image = UIImage(systemName: "circle.fill") ?? UIImage()
        return image.withTintColor(UIColor(color), renderingMode: .alwaysOriginal)
    }
}

/// A note's picture for the share sheet (Messages, Mail, Save Image…), written to a PNG only when shared.
struct NoteImage: Transferable {
    let note: Note

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { item in
            guard let url = await MainActor.run(body: { NotesStore.shared.imageFileURL(for: item.note) }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return SentTransferredFile(url)
        }
    }
}
