import SwiftUI

/// Edits a note in place; changes are saved (and synced) a moment after you stop typing.
struct NoteEditor: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note
    let onDelete: () -> Void
    @State private var title: String
    @State private var text: String
    @State private var image: UIImage?
    @State private var showOCR = false
    @State private var showImage = false
    @State private var saveTask: Task<Void, Never>?

    init(note: Note, onDelete: @escaping () -> Void) {
        self.note = note
        self.onDelete = onDelete
        _title = State(initialValue: note.title)
        _text = State(initialValue: note.body)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Title", text: $title, axis: .vertical)
                    .font(.title2.bold())

                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    FolderMenu(note: note, title: store.folderName(note.folderID) ?? "No Folder")
                        .font(.subheadline)
                    Spacer()
                }

                TagEditor(note: note)

                if note.hasImage {
                    imageSection
                }

                TextField(note.hasImage ? "Add a comment…" : "Write something…", text: $text, axis: .vertical)
                    .lineLimit(6...)
                    .padding(10)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

                if note.hasImage {
                    ocrSection
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(note.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if note.hasImage {
                    ShareLink(item: NoteImage(note: note), preview: SharePreview(note.displayTitle))
                } else {
                    ShareLink(item: text.isEmpty ? note.displayTitle : text)
                }
                Menu {
                    NoteActions(note: note, onDelete: delete)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .onChange(of: title) { scheduleSave() }
        .onChange(of: text) { scheduleSave() }
        .onDisappear {
            saveTask?.cancel()
            store.updateNote(id: note.id, title: title, body: text)
        }
        .task(id: "\(note.id)|\(note.imageKey ?? "")") {
            image = store.imageData(for: note).flatMap(UIImage.init(data:))
        }
        .fullScreenCover(isPresented: $showImage) {
            ImageViewer(image: image, note: note)
        }
    }

    private var meta: String {
        var parts = [note.createdAt.formatted(date: .long, time: .shortened)]
        switch note.source {
        case "screenshot": parts.append("Screenshot")
        case "photo": parts.append("Photo")
        case "service": parts.append("Saved from the right-click menu")
        case "clipboard": parts.append("From the clipboard")
        default: break
        }
        if let app = note.sourceApp { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var imageSection: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture { showImage = true }
                .contextMenu {
                    Button("Copy Image", systemImage: "doc.on.doc") { store.copyToPasteboard(note) }
                    ShareLink(item: NoteImage(note: note), preview: SharePreview(note.displayTitle)) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                }
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    @ViewBuilder private var ocrSection: some View {
        if store.ocrInProgress.contains(note.id) {
            HStack(spacing: 6) {
                ProgressView()
                Text("Reading the text in the image…").foregroundStyle(.secondary)
            }
            .font(.callout)
        } else {
            DisclosureGroup(isExpanded: $showOCR) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(note.ocrText.isEmpty ? "No text found." : note.ocrText)
                        .textSelection(.enabled)
                        .foregroundStyle(note.ocrText.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        if !note.ocrText.isEmpty {
                            Button("Copy Text", systemImage: "doc.on.doc") { store.copyText(note.ocrText) }
                        }
                        Spacer()
                        Button("Read Again", systemImage: "text.viewfinder") { store.runOCR(on: note) }
                    }
                    .font(.callout)
                }
                .padding(.top, 6)
            } label: {
                Text("Text in the image").font(.headline)
            }
        }
    }

    private func delete() {
        saveTask?.cancel()
        onDelete()
        store.deleteNote(note)
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
}

/// The picture full screen; pinch to zoom.
private struct ImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage?
    let note: Note
    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width * scale, height: geo.size.height * scale)
                    }
                }
                .gesture(MagnifyGesture().onChanged { scale = max(1, min(6, $0.magnification)) })
            }
            .background(.black)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: NoteImage(note: note), preview: SharePreview(note.displayTitle))
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

/// The tags on a note: chips to remove, a field to add, a menu of tags already in use.
struct TagEditor: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note
    @State private var newTag = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "number").foregroundStyle(.secondary)
                ForEach(note.tags, id: \.self) { tag in
                    let color = store.tagColor(tag)
                    Button {
                        store.setTags(note.tags.filter { $0 != tag }, for: note.id)
                    } label: {
                        HStack(spacing: 3) {
                            Text(tag)
                            Image(systemName: "xmark").font(.caption2.bold())
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background((color?.color ?? Brand.teal).opacity(color == nil ? 0.15 : 0.3), in: Capsule())
                }
                TextField("Add tag", text: $newTag)
                    .frame(minWidth: 80)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
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
                }
            }
        }
    }

    private func add() {
        // "work, ideas" adds two tags
        let typed = newTag.split(separator: ",").map(String.init)
        newTag = ""
        store.setTags(note.tags + typed, for: note.id)
    }
}
