import SwiftUI

/// Everything copied (and every screenshot), newest first.
struct InboxList: View {
    @EnvironmentObject private var store: NotesStore
    @Binding var selection: InboxItem.ID?
    var onSaved: (String) -> Void
    @State private var confirmClear = false

    var body: some View {
        List(selection: $selection) {
            ForEach(store.filteredInbox) { item in
                InboxRow(item: item)
                    .tag(item.id)
                    .itemProvider { store.dragProvider(for: item) }
                    .contextMenu {
                        Button("Save as Note") { save(item) }
                        if !store.folders.isEmpty {
                            Menu("Save to Folder") {
                                ForEach(store.folders) { folder in
                                    Button(folder.name) { save(item, in: folder.id) }
                                }
                            }
                        }
                        if let app = item.sourceApp {
                            Button("Always Save Copies From \(app) as Notes") {
                                var rules = InboxRules.all
                                rules.append(InboxRule(app: app, kind: .any, action: .saveAsNote))
                                InboxRules.all = rules
                                save(item)
                            }
                        }
                        Button("Copy") { store.copyToPasteboard(item) }
                        if item.kind == .image {
                            Button("Save Image As…") { if let url = store.imageFileURL(for: item) { ImageFiles.saveAs(url) } }
                        }
                        Divider()
                        Button("Remove from Inbox", role: .destructive) { store.deleteInboxItem(item) }
                        if let app = item.sourceApp, let id = IgnoredApps.bundleID(named: app) {
                            Button("Remove and Never Keep Copies from \(app)") {
                                IgnoredApps.add(id)
                                store.deleteInboxItem(item)
                            }
                        }
                    }
            }
        }
        .overlay {
            if store.filteredInbox.isEmpty {
                if store.searchText.isEmpty {
                    ContentUnavailableView("Nothing copied yet", systemImage: "doc.on.clipboard",
                                           description: Text("Text and images you copy, and screenshots you take, show up here."))
                } else {
                    ContentUnavailableView.search(text: store.searchText)
                }
            }
        }
        .navigationTitle("Inbox")
        .onDeleteCommand {
            if let item = store.inbox.first(where: { $0.id == selection }) { store.deleteInboxItem(item) }
        }
        .toolbar {
            ToolbarItem {
                Button { confirmClear = true } label: {
                    Label("Clear Inbox", systemImage: "trash")
                }
                .help("Remove everything from the Inbox. Saved notes stay.")
                .disabled(store.inbox.isEmpty)
            }
        }
        .confirmationDialog("Clear the Inbox?", isPresented: $confirmClear) {
            Button("Clear Inbox", role: .destructive) { store.clearInbox() }
        } message: {
            Text("Everything in the Inbox is removed. Notes you saved stay.")
        }
    }

    private func save(_ item: InboxItem, in folderID: String? = nil) {
        if let note = store.saveAsNote(item, inFolder: folderID) { onSaved(note.id) }
    }
}

struct InboxRow: View {
    @EnvironmentObject private var store: NotesStore
    let item: InboxItem
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if item.kind == .image, let path = item.imagePath {
                Thumbnail(source: .file(path), size: 44)
            } else {
                Image(systemName: "text.alignleft")
                    .frame(width: 44, height: 44)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.kind == .image && item.text.isEmpty ? "Image" : item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if item.source == "screenshot" { Image(systemName: "camera.viewfinder") }
                    Text([item.sourceApp, item.createdAt.formatted(.relative(presentation: .named))]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if hovering || copied {
                CopyButton(copied: $copied) { store.copyToPasteboard(item) }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct InboxDetail: View {
    @EnvironmentObject private var store: NotesStore
    let item: InboxItem
    var onSaved: (String) -> Void
    @State private var imageURL: URL?
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if item.kind == .image, let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .onDrag { store.dragProvider(for: item) }
                            .contextMenu { ImageMenu(fileURL: imageURL) { store.copyToPasteboard(item) } }
                            .help("Drag into Mail, Word or Finder. Right-click to save or share.")
                    } else if item.kind == .image {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        Text(item.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { store.copyToPasteboard(item) }
                    .help("Copy, ready to paste anywhere")
                if let imageURL {
                    ShareLink(item: imageURL) { Image(systemName: "square.and.arrow.up") }
                        .help("Share (Messages, Mail, AirDrop…)")
                } else if item.kind == .text {
                    ShareLink(item: item.text) { Image(systemName: "square.and.arrow.up") }
                        .help("Share (Messages, Mail, AirDrop…)")
                }
                Button(role: .destructive) { store.deleteInboxItem(item) } label: { Text("Remove") }
                if !store.folders.isEmpty {
                    Menu("Save to Folder") {
                        ForEach(store.folders) { folder in
                            Button(folder.name) { save(in: folder.id) }
                        }
                    }
                    .fixedSize()
                }
                Button { save() } label: { Label("Save as Note", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.teal)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(12)
        }
        .navigationTitle(item.source == "screenshot" ? "Screenshot" : "Copied")
        .task(id: item.id) {
            imageURL = nil
            guard item.kind == .image, let source = item.imageURL else { image = nil; return }
            let key = "file:" + source.path
            image = ImagePreview.cached(key)
            if image == nil {
                let loaded = await ImagePreview.load(key) { try? Data(contentsOf: source) }
                guard !Task.isCancelled else { return }
                image = loaded
            }
            let url = await store.preparedImageFileURL(for: item)
            guard !Task.isCancelled else { return }
            imageURL = url
        }
    }

    private var caption: String {
        var parts: [String] = []
        if item.source == "screenshot" { parts.append("Screenshot") }
        if let app = item.sourceApp { parts.append("from \(app)") }
        parts.append(item.createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private func save(in folderID: String? = nil) {
        if let note = store.saveAsNote(item, inFolder: folderID) { onSaved(note.id) }
    }
}
