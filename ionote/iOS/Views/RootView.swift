import SwiftUI

enum SidebarItem: Hashable {
    case all
    case folder(String)
    case tag(String)

    var folder: String? {
        if case .folder(let id) = self { return id }
        return nil
    }

    var tag: String? {
        if case .tag(let name) = self { return name }
        return nil
    }
}

/// Folders and tags, the notes in them, and the open note. On iPhone these stack; on iPad they sit side by side.
struct RootView: View {
    @EnvironmentObject private var store: NotesStore
    @State private var section: SidebarItem? = .all
    @State private var selectedNote: Note.ID?
    @State private var compactColumn = NavigationSplitViewColumn.content

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            Sidebar(section: $section)
        } content: {
            NotesList(selection: $selectedNote)
        } detail: {
            if let note = store.note(id: selectedNote) {
                NoteEditor(note: note) { selectedNote = nil }
                    .id(note.id)
            } else {
                ContentUnavailableView("No note selected", systemImage: "note.text")
            }
        }
        .onChange(of: section) { _, new in
            store.selectedFolder = new?.folder
            store.selectedTag = new?.tag
            selectedNote = nil
            compactColumn = .content
        }
        .onChange(of: store.folders) { _, folders in
            if let id = section?.folder, !folders.contains(where: { $0.id == id }) { section = .all }
        }
        .onChange(of: store.tags) { _, tags in
            if let tag = section?.tag, !tags.contains(where: { $0.name == tag }) { section = .all }
        }
        .onChange(of: selectedNote) { _, id in
            if id != nil { compactColumn = .detail }
        }
        .alert("Something went wrong", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var store: NotesStore
    @Binding var section: SidebarItem?
    @State private var creating = false
    @State private var naming: Folder?
    @State private var folderName = ""
    @State private var deleting: Folder?
    @State private var showSettings = false

    var body: some View {
        List(selection: $section) {
            Label("All Notes", systemImage: "note.text")
                .badge(store.totalNotes)
                .tag(SidebarItem.all)

            Section {
                ForEach(store.folders) { folder in
                    Label {
                        Text(folder.name)
                    } icon: {
                        Image(systemName: folder.color == nil ? "folder" : "folder.fill")
                            .foregroundStyle(folder.color?.color ?? Brand.teal)
                    }
                    .badge(folder.count)
                    .tag(SidebarItem.folder(folder.id))
                    .contextMenu {
                        Button("Rename…", systemImage: "pencil") { folderName = folder.name; naming = folder }
                        ColorMenu(selected: folder.color) { store.setColor($0, forFolder: folder) }
                        Button("Delete Folder…", systemImage: "trash", role: .destructive) { deleting = folder }
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = folder }
                    }
                }
                Button { folderName = ""; creating = true } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            } header: {
                Text("Folders")
            }

            if !store.tags.isEmpty {
                Section("Tags") {
                    ForEach(store.tags) { tag in
                        let color = store.tagColor(tag.name)
                        Label {
                            Text(tag.name)
                        } icon: {
                            Image(systemName: color == nil ? "number" : "tag.fill")
                                .foregroundStyle(color?.color ?? Brand.teal)
                        }
                        .badge(tag.count)
                        .tag(SidebarItem.tag(tag.name))
                        .contextMenu {
                            ColorMenu(selected: color) { store.setColor($0, forTag: tag.name) }
                        }
                    }
                }
            }

            Section {
                SyncStatusView()
            }
        }
        .navigationTitle("ionotes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                BrandTitle()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
        }
        .alert("New Folder", isPresented: $creating) {
            TextField("Name", text: $folderName)
            Button("Create") {
                if let folder = store.createFolder(named: folderName) { section = .folder(folder.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("For example Work or AI.")
        }
        .alert("Rename Folder", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $folderName)
            Button("Rename") { if let folder = naming { store.renameFolder(folder, to: folderName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete the folder \"\(deleting?.name ?? "")\"?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Folder", role: .destructive) { if let folder = deleting { store.deleteFolder(folder) } }
        } message: {
            Text("The notes in it are kept; they just won't be in a folder.")
        }
    }
}

/// The two-tone name in the navigation bar: teal "notes" in light mode, white in dark mode.
private struct BrandTitle: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { Brand.name(onLight: scheme == .light).font(.title3) }
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
                Label("On this device only", systemImage: "icloud.slash")
            case .noAccount(let why):
                Label(why, systemImage: "exclamationmark.icloud")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
