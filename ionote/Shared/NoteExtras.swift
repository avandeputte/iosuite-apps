import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The files attached to a note: tap one to look at it (Quick Look), attach more, take one off.
struct AttachmentsSection: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note
    @State private var previewURL: URL?
    @State private var importing = false
    @State private var dropping = false

    var body: some View {
        let files = store.attachments(of: note.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "paperclip").foregroundStyle(.secondary)
                Text(files.isEmpty ? "No files" : files.count == 1 ? "1 file" : "\(files.count) files")
                    .foregroundStyle(.secondary)
                if store.transferring.contains(note.id) {
                    ProgressView().controlSize(.small)
                    Text("Sending…").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    importing = true
                } label: {
                    Label("Attach File", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Attach a PDF, a picture or a document. Its text can be searched.")
            }
            .font(.callout)
            ForEach(files) { file in
                row(file)
            }
        }
        .padding(files.isEmpty ? 0 : 8)
        .background(files.isEmpty ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary.opacity(0.35)), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if dropping { RoundedRectangle(cornerRadius: 8).stroke(Brand.teal, lineWidth: 2) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { await store.attach(files: files, to: note.id) }
            return true
        } isTargeted: { dropping = $0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await store.attach(files: urls, to: note.id) }
            }
        }
        .quickLookPreview($previewURL)
    }

    private func row(_ file: Attachment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: file.symbol)
                .foregroundStyle(Brand.teal)
                .frame(width: 20)
            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if store.transferring.contains(file.id) {
                ProgressView().controlSize(.small)
            }
            Text(file.sizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { open(file) }
        .contextMenu {
            Button("Open") { open(file) }
            #if os(macOS)
            Button("Open With Default App") {
                Task { if let url = await store.localFile(for: file) { NSWorkspace.shared.open(url) } }
            }
            Button("Show in Finder") {
                Task { if let url = await store.localFile(for: file) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            }
            #endif
            Divider()
            Button("Remove File", role: .destructive) {
                Task { await store.removeAttachment(file) }
            }
        }
        .help("Click to look at it")
    }

    private func open(_ file: Attachment) {
        Task {
            if let url = await store.localFile(for: file) { previewURL = url }
        }
    }
}

/// "3/5" with a checklist symbol, and a paperclip with the number of files, for rows in the notes list.
struct NoteBadges: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note

    var body: some View {
        let counts = Markdown.taskCounts(note.body)
        let files = store.attachments(of: note.id).count
        if counts.total > 0 {
            Label("\(counts.done)/\(counts.total)", systemImage: counts.done == counts.total ? "checkmark.circle.fill" : "checklist")
                .labelStyle(CompactLabel())
                .foregroundStyle(counts.done == counts.total ? AnyShapeStyle(Brand.teal) : AnyShapeStyle(.tertiary))
        }
        if files > 0 {
            Label("\(files)", systemImage: "paperclip")
                .labelStyle(CompactLabel())
        }
    }
}

private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}

/// The templates as menu items (New Note ▾): picking one makes a note from it.
struct TemplateMenuItems: View {
    @EnvironmentObject private var store: NotesStore
    let made: (Note) -> Void

    var body: some View {
        if store.templates.isEmpty {
            Text("Make templates in the web app (Manage › Templates)")
        } else {
            ForEach(store.templates) { t in
                Button(t.name) {
                    if let note = store.createNote(from: t) { made(note) }
                }
            }
        }
    }
}

extension String {
    /// The text with a new, empty checklist item at the end ("- [ ] ").
    func addingChecklistItem() -> String {
        if isEmpty { return "- [ ] " }
        return self + (hasSuffix("\n") ? "" : "\n") + "- [ ] "
    }
}
