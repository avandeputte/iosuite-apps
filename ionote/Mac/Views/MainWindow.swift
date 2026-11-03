import SwiftUI
import UniformTypeIdentifiers

enum SidebarSection: Hashable {
    case inbox, notes
    case folder(String)
    case tag(String)

    var tag: String? {
        if case .tag(let name) = self { return name }
        return nil
    }

    var folder: String? {
        if case .folder(let id) = self { return id }
        return nil
    }
}

/// The ionotes window: Inbox and Notes in the sidebar, the list in the middle, the item on the right.
struct MainWindow: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var scheme
    @State private var section: SidebarSection? = .inbox
    @State private var selectedInbox: InboxItem.ID?
    @State private var selectedNote: Note.ID?

    var body: some View {
        NavigationSplitView {
            Sidebar(section: $section)
            .safeAreaInset(edge: .top, alignment: .leading) {
                Brand.name(onLight: scheme == .light)
                    .font(.title2)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
            .safeAreaInset(edge: .bottom, alignment: .leading) {
                SyncStatusView()
                    .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } content: {
            Group {
                switch section ?? .inbox {
                case .inbox:
                    InboxList(selection: $selectedInbox, onSaved: showNote)
                case .notes, .folder, .tag:
                    NotesList(selection: $selectedNote)
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 330)
        } detail: {
            switch section ?? .inbox {
            case .inbox:
                if let item = store.inbox.first(where: { $0.id == selectedInbox }) {
                    InboxDetail(item: item, onSaved: showNote)
                } else {
                    ContentUnavailableView("Pick something from the Inbox", systemImage: "tray",
                                           description: Text("Everything you copy lands in the Inbox. Save the ones worth keeping as notes."))
                }
            case .notes, .folder, .tag:
                if let note = store.note(id: selectedNote) {
                    NoteEditor(note: note).id(note.id)
                } else {
                    ContentUnavailableView("No note selected", systemImage: "note.text")
                }
            }
        }
        .searchable(text: $store.searchText, prompt: "Search notes")
        .onChange(of: section) { _, new in
            store.selectedFolder = new?.folder
            store.selectedTag = new?.tag
        }
        .onChange(of: store.folders) { _, folders in
            // The open folder was deleted (here or on another device): go back to all notes.
            if let id = section?.folder, !folders.contains(where: { $0.id == id }) { section = .notes }
        }
        .onChange(of: store.tags) { _, tags in
            // The last note with the open tag lost it: go back to all notes.
            if let tag = section?.tag, !tags.contains(where: { $0.name == tag }) { section = .notes }
        }
        .onChange(of: store.searchText) { old, new in
            // Searching is about notes: jump there when a search starts.
            if old.isEmpty, !new.isEmpty, section == .inbox { section = .notes }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: newNote) {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .help("Write a new note (⌘N)")
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .frame(minWidth: 820, minHeight: 480)
        .onReceive(NotificationCenter.default.publisher(for: .ionotesNewNote)) { _ in newNote() }
        .onAppear { Router.openSettings = openSettings }
    }

    private func showNote(_ id: String) {
        store.searchText = ""
        // Open the note where it lives: its folder, or All Notes.
        section = store.note(id: id)?.folderID.map { .folder($0) } ?? .notes
        selectedNote = id
    }

    private func newNote() {
        if let note = store.createBlankNote() { showNote(note.id) }
    }
}

/// "Syncing with iCloud", or why not.
struct SyncStatusView: View {
    @EnvironmentObject private var store: NotesStore

    var body: some View {
        Group {
            switch store.syncState {
            case .checking:
                Label("Checking iCloud…", systemImage: "icloud")
            case .syncing:
                Label("Syncing with iCloud", systemImage: "checkmark.icloud")
            case .localOnly:
                Label("On this Mac only", systemImage: "icloud.slash")
                    .help("This build isn't signed for iCloud. See the README to turn on sync.")
            case .noAccount(let why):
                Label("iCloud off", systemImage: "exclamationmark.icloud")
                    .help(why)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Inbox, all notes, folders (drop notes on one to file them) and tags.
struct Sidebar: View {
    @EnvironmentObject private var store: NotesStore
    @Binding var section: SidebarSection?
    @State private var naming: Folder?
    @State private var creating = false
    @State private var folderName = ""
    @State private var deleting: Folder?

    var body: some View {
        List(selection: $section) {
            Label("Inbox", systemImage: "tray")
                .badge(store.inbox.count)
                .tag(SidebarSection.inbox)
            DropRow(folderID: nil) {
                Label("All Notes", systemImage: "note.text")
                    .badge(store.totalNotes)
            }
            .tag(SidebarSection.notes)

            Section {
                ForEach(store.folders) { folder in
                    DropRow(folderID: folder.id) {
                        Label {
                            Text(folder.name)
                        } icon: {
                            Image(systemName: folder.color == nil ? "folder" : "folder.fill")
                                .foregroundStyle(folder.color?.color ?? Color.accentColor)
                        }
                        .badge(folder.count)
                    }
                    .tag(SidebarSection.folder(folder.id))
                    .contextMenu {
                        Button("Rename…") { folderName = folder.name; naming = folder }
                        ColorMenu(selected: folder.color) { store.setColor($0, forFolder: folder) }
                        Button("Delete Folder…", role: .destructive) { deleting = folder }
                    }
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button { folderName = ""; creating = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New folder")
                }
            }

            if !store.tags.isEmpty {
                Section("Tags") {
                    ForEach(store.tags) { tag in
                        Label {
                            Text(tag.name)
                        } icon: {
                            Image(systemName: store.tagColor(tag.name) == nil ? "number" : "tag.fill")
                                .foregroundStyle(store.tagColor(tag.name)?.color ?? Color.accentColor)
                        }
                        .badge(tag.count)
                        .tag(SidebarSection.tag(tag.name))
                        .contextMenu {
                            ColorMenu(selected: store.tagColor(tag.name)) { store.setColor($0, forTag: tag.name) }
                        }
                    }
                }
            }
        }
        .alert("New Folder", isPresented: $creating) {
            TextField("Name", text: $folderName)
            Button("Create") {
                if let folder = store.createFolder(named: folderName) { section = .folder(folder.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("For example Work or AI. Drag notes onto it to file them.")
        }
        .alert("Rename Folder", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $folderName)
            Button("Rename") { if let folder = naming { store.renameFolder(folder, to: folderName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete the folder \"\(deleting?.name ?? "")\"?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Folder", role: .destructive) { if let folder = deleting { store.deleteFolder(folder) } }
        } message: {
            Text("The notes in it are kept; they just won't be in a folder.")
        }
    }
}

/// A sidebar row that files notes dropped on it into a folder (nil: out of any folder).
private struct DropRow<Content: View>: View {
    @EnvironmentObject private var store: NotesStore
    let folderID: String?
    @ViewBuilder let content: Content
    @State private var targeted = false

    var body: some View {
        content
            .background(targeted ? Brand.teal.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .onDrop(of: [.ionotesNote], isTargeted: $targeted) { providers in
                for provider in providers {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.ionotesNote.identifier) { data, _ in
                        guard let data, let id = String(data: data, encoding: .utf8) else { return }
                        Task { @MainActor in store.moveNote(id: id, toFolder: folderID) }
                    }
                }
                return true
            }
    }
}
