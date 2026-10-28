import SwiftUI

/// The changes iopix made to one photo, newest first, each with what it can bring back (undo the change, put the
/// sidecar or the original file back, restore from the trash).
struct EditHistoryView: View {
    let photo: Int
    var restored: () -> Void = {}

    struct Entry: Identifiable {
        let id: Int, ts: Double, user: String, action: String, summary: String, restore: [String]
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var rights = EditRights.shared
    @State private var entries: [Entry]?
    @State private var total = 0
    @State private var toast: String?
    @State private var working: Int?
    @State private var problem: String?

    static let actions = ["edit": "Edit", "face": "Face", "tag": "Tag", "deleted": "Deleted", "trashed": "Trashed", "moved": "Moved",
                          "restore": "Restore", "sync": "Sync", "database": "digiKam", "revert": "Undo", "added": "Added",
                          "guard": "Protected", "lossless": "File"]
    static let restoreLabels = ["undo": "Undo", "trash": "Restore from trash", "sidecar": "Restore sidecar",
                                "original": "Restore original file", "deleted": "Restore photo"]

    var body: some View {
        NavigationStack {
            List {
                if let problem {
                    Text("Couldn't load the edit log: \(problem)").foregroundStyle(.secondary)
                } else if let entries {
                    if entries.isEmpty { Text("iopix hasn't changed this photo.").foregroundStyle(.secondary) }
                    ForEach(entries) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(Self.actions[e.action] ?? e.action.capitalized).font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Hue.indigo.opacity(0.14), in: Capsule())
                                Text(e.summary).font(.subheadline)
                            }
                            Text("\(Date(timeIntervalSince1970: e.ts).formatted(date: .abbreviated, time: .shortened))\(e.user.isEmpty ? "" : " · \(e.user)")")
                                .font(.caption).foregroundStyle(.secondary)
                            if rights.canWrite, !e.restore.isEmpty {
                                HStack(spacing: 14) {
                                    ForEach(e.restore, id: \.self) { k in
                                        Button(Self.restoreLabels[k] ?? k.capitalized) { Task { await restore(e, k) } }
                                            .font(.caption).buttonStyle(.borderless)
                                    }
                                    if working == e.id { ProgressView() }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    if total > entries.count { Text("\(total - entries.count) older changes are in the full edit log.").font(.footnote).foregroundStyle(.secondary) }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Edit log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { BarText("Done") } } }
            .refreshable { await load() }
            .editToast($toast)
        }
        .task { await rights.refresh(); await load() }
    }

    private func load() async {
        let r: [String: Any]
        do {
            r = try await EditAPI.get("api/history", [URLQueryItem(name: "photo", value: "\(photo)"), URLQueryItem(name: "limit", value: "100")])
        } catch {
            problem = error.localizedDescription
            return
        }
        problem = nil
        total = (r["total"] as? NSNumber)?.intValue ?? 0
        entries = (r["entries"] as? [[String: Any]] ?? []).compactMap { e in
            guard let id = (e["id"] as? NSNumber)?.intValue else { return nil }
            return Entry(id: id, ts: (e["ts"] as? NSNumber)?.doubleValue ?? 0, user: e["user"] as? String ?? "",
                         action: e["action"] as? String ?? "", summary: e["summary"] as? String ?? "",
                         restore: e["restore"] as? [String] ?? [])
        }
    }

    private func restore(_ e: Entry, _ kind: String) async {
        working = e.id
        defer { working = nil }
        do {
            try await EditAPI.post("api/history/\(e.id)/restore", ["kind": kind])
            toast = kind == "deleted" ? "Photo restored." : "Restored."
            restored()
            await load()
        } catch {
            toast = error.localizedDescription
        }
    }
}

/// Every metadata field of the photo's file and sidecar, searchable; editors can change the editable ones (written
/// to the sidecar or file by the server) and read the file again.
struct EditMetadataView: View {
    let photo: Int
    var saved: () -> Void = {}

    struct Field: Identifiable, Hashable {
        let group: String, tag: String, value: String, editable: Bool, source: String
        var id: String { "\(source)|\(group)|\(tag)" }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var rights = EditRights.shared
    @State private var fields: [Field]?
    @State private var problem: String?
    @State private var filter = ""
    @State private var source = "all"
    @State private var changed: [String: (group: String, tag: String, value: String)] = [:]
    @State private var editing: Field?
    @State private var value = ""
    @State private var adding = false
    @State private var addGroup = "XMP-dc"
    @State private var addTag = ""
    @State private var addValue = ""
    @State private var toast: String?
    @State private var saving = false

    private var shown: [Field] {
        (fields ?? []).filter { (source == "all" || $0.source == source) &&
            (filter.isEmpty || "\($0.group) \($0.tag) \($0.value)".localizedCaseInsensitiveContains(filter)) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let problem { Text(problem).foregroundStyle(.secondary) }
                Picker("Show", selection: $source) {
                    Text("All").tag("all"); Text("File").tag("file"); Text("Sidecar").tag("sidecar")
                }
                .pickerStyle(.segmented)
                ForEach(Dictionary(grouping: shown, by: \.group).sorted { $0.key < $1.key }, id: \.key) { group, list in
                    Section(group) {
                        ForEach(list) { f in
                            Button {
                                guard rights.canWrite, f.editable else { return }
                                editing = f
                                value = changed[f.id]?.value ?? f.value
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(f.tag).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        if f.editable && rights.canWrite { Image(systemName: "pencil").font(.caption2).foregroundStyle(.tertiary) }
                                        if changed[f.id] != nil { Text("changed").font(.caption2).foregroundStyle(Hue.orange) }
                                    }
                                    Text(changed[f.id]?.value ?? f.value).font(.footnote).foregroundStyle(.primary).textSelection(.enabled)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if rights.canWrite {
                    Section {
                        Button { adding = true } label: { Label("Add a field…", systemImage: "plus") }
                        Button { Task { await reread() } } label: { Label("Read again from the file and sidecar", systemImage: "arrow.clockwise") }
                    }
                }
            }
            .searchable(text: $filter, prompt: "Filter fields")
            .navigationTitle("All metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Close") } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else if !changed.isEmpty {
                        Button { Task { await save() } } label: { BarText("Save \(changed.count)") }
                    }
                }
            }
            .editToast($toast)
            .alert(editing?.tag ?? "", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Value", text: $value)
                Button("Cancel", role: .cancel) {}
                Button("Change") { if let f = editing { changed[f.id] = (f.group, f.tag, value) } }
            } message: { Text(editing?.group ?? "") }
            .alert("Add a field", isPresented: $adding) {
                TextField("Group (e.g. XMP-dc)", text: $addGroup)
                TextField("Field (e.g. Title)", text: $addTag)
                TextField("Value", text: $addValue)
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    let t = addTag.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { changed["new|\(addGroup)|\(t)"] = (addGroup, t, addValue); toast = "Added; save to write it." }
                }
            }
        }
        .task { await rights.refresh(); await load() }
    }

    private func load() async {
        do {
            let r = try await EditAPI.get("api/metadata/\(photo)")
            func parse(_ k: String) -> [Field] {
                (r[k] as? [[String: Any]] ?? []).map { f in
                    let v = f["value"]
                    let text = (v as? String) ?? (v as? NSNumber)?.stringValue ?? (v.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                    return Field(group: f["group"] as? String ?? "", tag: f["tag"] as? String ?? "", value: text,
                                 editable: f["editable"] as? Bool ?? false, source: k)
                }
            }
            fields = parse("file") + parse("sidecar")
            problem = nil
        } catch {
            problem = error.localizedDescription
            fields = fields ?? []
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await EditAPI.post("api/metadata/\(photo)", ["changes": changed.values.map { ["group": $0.group, "tag": $0.tag, "value": $0.value] }])
            changed = [:]
            toast = "Saved."
            saved()
            await load()
        } catch {
            toast = error.localizedDescription
        }
    }

    private func reread() async {
        do {
            try await EditAPI.post("api/metadata/\(photo)/reread", [:])
            toast = "Read again from the file and sidecar."
            saved()
            await load()
        } catch {
            toast = error.localizedDescription
        }
    }
}
