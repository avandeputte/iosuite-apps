import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// One transaction: what the bank said, what it was made of here (payee, category, notes, tags), its receipts.
struct TransactionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var transaction: Transaction
    /// It was opened from the Needs a look list: it can be marked as looked at.
    var needsLook = false
    /// The transaction as it is now; nil when it left the list it was opened from.
    let onChanged: (Transaction?) -> Void

    @State private var editing = false
    @State private var busy = false
    @State private var preview: URL?
    @State private var pickingPhoto = false
    @State private var picked: PhotosPickerItem?
    @State private var takingPhoto = false
    @State private var pickingFile = false

    private var t: Transaction { transaction }
    private var writable: Bool { t.writable ?? false }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Text(Money.text(t.amount, t.currency, sign: t.amount > 0)).font(.largeTitle.bold()).monospacedDigit()
                        .foregroundStyle(t.amount > 0 ? Color.green : Color.primary)
                    Text(t.title).font(.headline)
                    Text(Day.date(t.day).formatted(date: .complete, time: .omitted)).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section {
                LabeledContent("Account", value: t.account ?? "")
                if let tr = t.transfer {
                    LabeledContent(t.amount < 0 ? "Transfer to" : "Transfer from", value: tr.account ?? "another account")
                } else {
                    LabeledContent("Category", value: [t.category, t.group].compactMap { $0 }.joined(separator: " · ").isEmpty ? "None" : [t.category, t.group].compactMap { $0 }.joined(separator: " · "))
                }
                if let d = t.description, !d.isEmpty, d != t.merchant { LabeledContent("At the bank", value: d) }
                if !t.tags.isEmpty { LabeledContent("Tags", value: t.tags.joined(separator: ", ")) }
                if t.hidden { Label("Hidden: left out of the lists and the sums", systemImage: "eye.slash").foregroundStyle(.secondary) }
            }
            if let n = t.notes, !n.isEmpty {
                Section("Notes") { Text(n).textSelection(.enabled) }
            }
            Section {
                ForEach(t.receipts ?? []) { r in
                    Button { open(r) } label: {
                        Label { Text(r.name).foregroundStyle(.primary) } icon: { Image(systemName: r.mime == "application/pdf" ? "doc.richtext" : "photo") }
                    }
                    .swipeActions {
                        if writable { Button(role: .destructive) { remove(r) } label: { Label("Remove", systemImage: "trash") } }
                    }
                }
                if writable {
                    Menu {
                        Button { pickingPhoto = true } label: { Label("Choose a photo", systemImage: "photo") }
                        if CameraPicker.available {
                            Button { takingPhoto = true } label: { Label("Take a photo", systemImage: "camera") }
                        }
                        Button { pickingFile = true } label: { Label("Choose a file", systemImage: "folder") }
                    } label: {
                        Label("Add a receipt", systemImage: "plus")
                    }
                }
            } header: {
                Text("Receipts")
            }
            if needsLook, writable {
                Section {
                    Button { looked() } label: { Label("Looked at", systemImage: "checkmark.circle") }
                } footer: {
                    Text("Takes it off the Needs a look list.")
                }
            }
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if writable { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } } }
        }
        .overlay { if busy { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
        .sheet(isPresented: $editing) {
            TransactionEditor(transaction: t) { changed in
                transaction = changed
                onChanged(changed)
                model.changes += 1
            }
        }
        .quickLookPreview($preview)
        .photosPicker(isPresented: $pickingPhoto, selection: $picked, matching: .images)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data), let jpeg = image.jpeg() {
                    await add(jpeg, mime: "image/jpeg", name: "receipt.jpg")
                }
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                if let jpeg = image.jpeg() { Task { await add(jpeg, mime: "image/jpeg", name: "receipt.jpg") } }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            Task { await add(data, mime: mime, name: url.lastPathComponent) }
        }
        .task { await reload() }
    }

    private func reload() async {
        guard let api = model.api, let fresh = try? await api.transaction(t.id) else { return }
        transaction = fresh
    }

    private func add(_ data: Data, mime: String, name: String) async {
        guard let api = model.api else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await api.addReceipt(t.id, data: data, mime: mime, name: name)
            await reload()
            onChanged(transaction)
        } catch {
            model.failed(error)
        }
    }

    /// The receipt's file, fetched and shown; it is removed from the device when the app next starts.
    private func open(_ r: Receipt) {
        guard let api = model.api else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let data = try await api.receipt(r.id)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("receipts", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("\(r.id)-" + r.name.replacingOccurrences(of: "/", with: "-"))
                try data.write(to: file, options: [.atomic, .completeFileProtection])
                preview = file
            } catch {
                model.failed(error)
            }
        }
    }

    private func remove(_ r: Receipt) {
        guard let api = model.api else { return }
        Task {
            do {
                try await api.deleteReceipt(r.id)
                await reload()
                onChanged(transaction)
            } catch {
                model.failed(error)
            }
        }
    }

    private func looked() {
        guard let api = model.api else { return }
        Task {
            do {
                _ = try await api.review([t.id])
                onChanged(nil)
                await model.refresh()
                dismiss()
            } catch {
                model.failed(error)
            }
        }
    }
}

/// What can be changed of a transaction here: its payee, category, notes, tags, and whether it is hidden. Kept as
/// changed, also by the next sync with Monarch Money; nothing is changed in Monarch.
struct TransactionEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let transaction: Transaction
    let onSaved: (Transaction) -> Void

    @State private var merchant = ""
    @State private var category = ""
    @State private var notes = ""
    @State private var tags = ""
    @State private var hidden = false
    @State private var filled = false
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Payee") { TextField("Payee", text: $merchant) }
                if transaction.transfer == nil {
                    Section {
                        Picker("Category", selection: $category) {
                            Text("None").tag("")
                            if !category.isEmpty, !model.categories.contains(where: { $0.category == category }) { Text(category).tag(category) }
                            ForEach(model.categories, id: \.category) { Text($0.category).tag($0.category) }
                        }
                        .pickerStyle(.navigationLink)
                    }
                }
                Section("Notes") { TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...6) }
                Section {
                    TextField("holiday, work", text: $tags).textInputAutocapitalization(.never)
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Commas between tags.")
                }
                Section {
                    Toggle("Hidden", isOn: $hidden)
                } footer: {
                    Text("A hidden transaction is left out of the lists and the sums.")
                }
                if let failure { Section { Text(failure).foregroundStyle(.red).font(.callout) } }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(working) }
            }
            .onAppear {
                guard !filled else { return }
                filled = true
                merchant = transaction.merchant ?? ""
                category = transaction.category ?? ""
                notes = transaction.notes ?? ""
                tags = (transaction.ownTags ?? []).joined(separator: ", ")
                hidden = transaction.hidden
            }
        }
    }

    private func save() {
        guard let api = model.api else { return }
        // only what was changed is sent: a field left as it was is not marked as changed here
        var fields: [String: Any] = [:]
        if merchant != (transaction.merchant ?? "") { fields["merchant"] = merchant }
        if category != (transaction.category ?? "") { fields["category"] = category }
        if notes != (transaction.notes ?? "") { fields["notes"] = notes }
        let own = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if own != (transaction.ownTags ?? []) { fields["tags"] = own }
        if hidden != transaction.hidden { fields["hidden"] = hidden }
        guard !fields.isEmpty else { dismiss(); return }
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                onSaved(try await api.change(transaction.id, fields))
                dismiss()
            } catch {
                if case APIError.signedOut = error { model.failed(error) } else { failure = error.localizedDescription }
            }
        }
    }
}
