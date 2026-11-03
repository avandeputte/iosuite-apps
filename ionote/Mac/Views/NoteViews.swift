import SwiftUI

struct NotesList: View {
    @EnvironmentObject private var store: NotesStore
    @Binding var selection: Note.ID?

    var body: some View {
        List(selection: $selection) {
            ForEach(store.notes) { note in
                NoteRow(note: note)
                    .tag(note.id)
                    // Drag a note into Mail, Word, Finder…: images go as a PNG file, text as text.
                    .itemProvider { store.dragProvider(for: note) }
                    .contextMenu {
                        Button("Copy") { store.copyToPasteboard(note) }
                        if note.hasImage {
                            Button("Save Image As…") { if let url = store.imageFileURL(for: note) { ImageFiles.saveAs(url) } }
                        }
                        Button(note.pinned ? "Unpin" : "Pin to Top") { store.togglePin(note) }
                        FolderMenu(note: note, title: "Move to Folder")
                        if !store.tags.isEmpty {
                            Menu("Tags") {
                                ForEach(store.tags) { tag in
                                    let has = note.tags.contains { $0.caseInsensitiveCompare(tag.name) == .orderedSame }
                                    Button {
                                        store.setTags(has ? note.tags.filter { $0.caseInsensitiveCompare(tag.name) != .orderedSame }
                                                          : note.tags + [tag.name], for: note.id)
                                    } label: {
                                        if has { Label(tag.name, systemImage: "checkmark") } else { Text(tag.name) }
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Delete Note", role: .destructive) { delete(note) }
                    }
            }
        }
        .overlay {
            if store.notes.isEmpty {
                if !store.searchText.isEmpty {
                    ContentUnavailableView.search(text: store.searchText)
                } else if store.selectedTag != nil {
                    ContentUnavailableView("No notes with this tag", systemImage: "number")
                } else {
                    ContentUnavailableView("No notes yet", systemImage: "note.text",
                                           description: Text("Save something from the Inbox, or select text in any app and right-click › Save to ionotes."))
                }
            }
        }
        .navigationTitle(!store.searchText.isEmpty ? "Search"
                         : store.selectedTag.map { "#\($0)" } ?? store.folderName(store.selectedFolder) ?? "All Notes")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: $store.sort) {
                        ForEach(NoteSort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort notes. Pinned notes stay on top.")
            }
        }
        // ⌘C copies the selected note, ready to paste anywhere. It doesn't land in the Inbox.
        .onCopyCommand {
            store.note(id: selection).map { [store.copyProvider(for: $0)] } ?? []
        }
        .onDeleteCommand {
            if let note = store.note(id: selection) { delete(note) }
        }
    }

    private func delete(_ note: Note) {
        if selection == note.id { selection = nil }
        store.deleteNote(note)
    }
}

struct NoteRow: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if note.hasImage {
                Thumbnail(source: .note(id: note.id, version: note.imageKey), size: 44)
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
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Image(systemName: NoteRow.icon(for: note.source))
                    Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                    ForEach(note.tags.prefix(3), id: \.self) { TagChip(name: $0) }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if hovering || copied {
                CopyButton(copied: $copied) { store.copyToPasteboard(note) }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    static func icon(for source: String) -> String {
        switch source {
        case "screenshot": return "camera.viewfinder"
        case "service": return "cursorarrow.click.2"
        case "clipboard": return "doc.on.clipboard"
        default: return "square.and.pencil"
        }
    }
}

/// Files a note in a folder: a submenu in context menus, or a "📁 Work" pop-up in the editor.
struct FolderMenu: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note
    let title: String?

    var body: some View {
        Menu {
            Button {
                store.moveNote(id: note.id, toFolder: nil)
            } label: {
                if note.folderID == nil { Label("No Folder", systemImage: "checkmark") } else { Text("No Folder") }
            }
            if !store.folders.isEmpty { Divider() }
            ForEach(store.folders) { folder in
                Button {
                    store.moveNote(id: note.id, toFolder: folder.id)
                } label: {
                    if note.folderID == folder.id { Label(folder.name, systemImage: "checkmark") } else { Text(folder.name) }
                }
            }
        } label: {
            if let title {
                Text(title)
            } else {
                Label(store.folderName(note.folderID) ?? "No Folder", systemImage: "folder")
                    .font(.caption)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the folder this note is in")
    }
}

/// A small copy button that says "Copied" for a moment.
struct CopyButton: View {
    @Binding var copied: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(copied ? "Copied" : "Copy, ready to paste anywhere")
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

/// The tags on a note: chips to remove, a field to add, a menu of tags already in use.
struct TagEditor: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note
    @State private var newTag = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "number").foregroundStyle(.secondary)
            ForEach(note.tags, id: \.self) { tag in
                HStack(spacing: 2) {
                    Text(tag)
                    Button {
                        store.setTags(note.tags.filter { $0 != tag }, for: note.id)
                    } label: {
                        Image(systemName: "xmark").font(.caption2.bold())
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this tag")
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background((store.tagColor(tag)?.color ?? Brand.teal).opacity(store.tagColor(tag) == nil ? 0.15 : 0.3), in: Capsule())
            }
            TextField("Add tag", text: $newTag)
                .textFieldStyle(.plain)
                .frame(minWidth: 70, maxWidth: 140)
                .onSubmit(add)
            let unused = store.tags.map(\.name).filter { name in !note.tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
            if !unused.isEmpty {
                Menu {
                    ForEach(unused, id: \.self) { name in
                        Button(name) { store.setTags(note.tags + [name], for: note.id) }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a tag you already use")
            }
            Spacer(minLength: 0)
        }
    }

    private func add() {
        // "work, ideas" adds two tags
        let typed = newTag.split(separator: ",").map(String.init)
        newTag = ""
        store.setTags(note.tags + typed, for: note.id)
    }
}

/// Edits a note in place; changes are saved (and synced) a moment after you stop typing.
struct NoteEditor: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note
    @State private var title: String
    @State private var text: String
    @State private var image: NSImage?
    @State private var imageURL: URL?
    @State private var showOCR = true
    @State private var saveTask: Task<Void, Never>?

    init(note: Note) {
        self.note = note
        _title = State(initialValue: note.title)
        _text = State(initialValue: note.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.bold())

            HStack {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                FolderMenu(note: note, title: nil)
            }

            TagEditor(note: note)

            if note.hasImage {
                imageSection
            }

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(note.hasImage ? "Add a comment…" : "Write something…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 120)

            if note.hasImage {
                ocrSection
            }
        }
        .padding(20)
        .navigationTitle(note.displayTitle)
        .toolbar {
            ToolbarItemGroup {
                Button { store.togglePin(note) } label: {
                    Label(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin")
                }
                .help(note.pinned ? "Unpin this note" : "Keep this note at the top of the list")
                Button { store.copyToPasteboard(note) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy, ready to paste anywhere (it doesn't go into the Inbox)")
                // Messages, Mail, AirDrop, Notes…: the picture for image notes, the text otherwise.
                if let imageURL {
                    ShareLink(item: imageURL)
                        .help("Share the picture")
                } else if !note.hasImage {
                    ShareLink(item: text.isEmpty ? note.displayTitle : text)
                        .help("Share the text")
                }
                Button(role: .destructive) { store.deleteNote(note) } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete this note on all your devices")
            }
        }
        .onChange(of: title) { scheduleSave() }
        .onChange(of: text) { scheduleSave() }
        .onDisappear {
            saveTask?.cancel()
            store.updateNote(id: note.id, title: title, body: text)
        }
        .task(id: "\(note.id)|\(note.imageKey ?? "")") {
            imageURL = nil
            guard note.hasImage else { image = nil; return }
            let key = "note:\(note.id)/\(note.imageKey ?? "")"
            image = ImagePreview.cached(key)
            if image == nil, let data = store.imageData(for: note) {
                let loaded = await ImagePreview.load(key) { data }
                guard !Task.isCancelled else { return }
                image = loaded
            }
            // The PNG for dragging, sharing and Preview is written in the background, once per note.
            let url = await store.preparedImageFileURL(for: note)
            guard !Task.isCancelled else { return }
            imageURL = url
        }
    }

    private var meta: String {
        var parts = [note.createdAt.formatted(date: .long, time: .shortened)]
        switch note.source {
        case "screenshot": parts.append("Screenshot")
        case "service": parts.append("Saved from the right-click menu")
        case "clipboard": parts.append("From the clipboard")
        default: break
        }
        if let app = note.sourceApp { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var imageSection: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 340)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture(count: 2) { openInPreview() }
                .onDrag { store.dragProvider(for: note) }
                .contextMenu { ImageMenu(fileURL: imageURL) { store.copyToPasteboard(note) } }
                .help("Drag into Mail, Word or Finder. Right-click to save or share. Double-click to open in Preview.")
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    @ViewBuilder private var ocrSection: some View {
        if store.ocrInProgress.contains(note.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading the text in the image…").foregroundStyle(.secondary)
            }
            .font(.callout)
        } else {
            DisclosureGroup(isExpanded: $showOCR) {
                ScrollView {
                    Text(note.ocrText.isEmpty ? "No text found." : note.ocrText)
                        .textSelection(.enabled)
                        .foregroundStyle(note.ocrText.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            } label: {
                HStack {
                    Text("Text in the image")
                    Spacer()
                    if !note.ocrText.isEmpty {
                        Button("Copy Text") { store.copyText(note.ocrText) }
                        .buttonStyle(.link)
                    }
                    Button("Read Again") { store.runOCR(on: note) }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let id = note.id, newTitle = title, newText = text
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            store.updateNote(id: id, title: newTitle, body: newText)
        }
    }

    private func openInPreview() {
        if let url = imageURL ?? store.imageFileURL(for: note) { NSWorkspace.shared.open(url) }
    }
}
