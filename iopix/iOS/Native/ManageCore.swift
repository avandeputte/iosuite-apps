import SwiftUI
import PhotosUI

/// Small helpers the library-management pages share: JSON posts, multipart uploads of several files, who may change
/// things, and a notice for the outcome of an action.
enum ManageAPI {
    /// POST a JSON body; the answer, or the server's reason it refused.
    @discardableResult
    static func post(_ path: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        var r = IopixClient.shared.request(path, method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await IopixClient.shared.session.data(for: r)
        return try IopixClient.shared.check(data, resp)
    }

    static func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> [String: Any] {
        try await IopixClient.shared.json(path, query: query)
    }

    /// Sends several files in one multipart request (`files` repeated, plus text fields), streamed from a body file.
    static func upload(_ path: String, files: [URL], fields: [String: String] = [:]) async throws -> [String: Any] {
        let boundary = "iopix-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("manage-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: body.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: body) }
        let sink = try FileHandle(forWritingTo: body)
        do {
            for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
                try sink.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
            }
            for file in files {
                let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
                try sink.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
                let src = try FileHandle(forReadingFrom: file)
                while let chunk = try src.read(upToCount: 4 << 20), !chunk.isEmpty { try sink.write(contentsOf: chunk) }
                try src.close()
                try sink.write(contentsOf: Data("\r\n".utf8))
            }
            try sink.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
            try sink.close()
        } catch {
            try? sink.close()
            throw error
        }
        var r = IopixClient.shared.request(path, method: "POST")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await IopixClient.shared.session.upload(for: r, fromFile: body)
        return try IopixClient.shared.check(data, resp)
    }

    /// The files picked in the photo picker, copied out as originals (removed again by `cleanUp`).
    static func files(from items: [PhotosPickerItem]) async -> [URL] {
        var out: [URL] = []
        for item in items {
            if let f = try? await item.loadTransferable(type: PickedFile.self) { out.append(f.url) }
        }
        return out
    }

    static func cleanUp(_ files: [URL]) {
        for f in files { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
    }

    static func plural(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n.formatted()) \(word)s" }

    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}

/// Who is signed in, for showing or hiding the buttons that change things (the server checks again).
@MainActor
final class ManageRights: ObservableObject {
    @Published var account: Account?
    var canWrite: Bool { account?.canWrite == true }
    var isAdmin: Bool { account?.isAdmin == true }

    func load() async { account = try? await IopixClient.shared.account() }
}

/// A short message after an action (what happened, or why it didn't).
struct Notice: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var failed = false
}

extension View {
    /// Shows a notice as an alert.
    func notice(_ n: Binding<Notice?>) -> some View {
        alert(n.wrappedValue?.failed == true ? "Couldn't do that" : "Done", isPresented: Binding(get: { n.wrappedValue != nil }, set: { if !$0 { n.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(n.wrappedValue?.text ?? "") }
    }

    /// A one-field prompt (a name), with a confirm button.
    func namePrompt(_ title: String, isPresented: Binding<Bool>, text: Binding<String>, action: String = "Save", message: String? = nil,
                    onSave: @escaping (String) -> Void) -> some View {
        alert(title, isPresented: isPresented) {
            TextField("Name", text: text)
            Button("Cancel", role: .cancel) {}
            Button(action) {
                let t = text.wrappedValue.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { onSave(t) }
            }
        } message: { if let message { Text(message) } }
    }
}

/// A row of photo thumbnails at their own shapes, scrolling sideways; tap one to see it full screen.
struct ManageThumbStrip: View {
    struct Item: Identifiable {
        let id: Int
        var ratio: Double = 1.4
        var caption: String? = nil
        var badge: String? = nil
        var selected = false
    }
    let items: [Item]
    var height: CGFloat = 110
    var onTap: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, x in
                    Button { onTap(i) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            RemoteImage(path: "thumb/\(x.id)")
                                .frame(width: height * CGFloat(min(2, max(0.5, x.ratio))), height: height)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(alignment: .topLeading) {
                                    if let b = x.badge {
                                        Text(b).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Hue.amber, in: Capsule()).foregroundStyle(.white).padding(5)
                                    }
                                }
                                .overlay(alignment: .topTrailing) {
                                    if x.selected {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor).font(.title3).padding(5)
                                    }
                                }
                            if let c = x.caption {
                                Text(c).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    .frame(width: height * CGFloat(min(2, max(0.5, x.ratio))), alignment: .leading)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}


/// The size of the photos on the management screens, as the web app's List / Large / Larger choice; one setting for
/// all of them, kept on this device.
enum ManageThumbSize {
    static let key = "iopix.manage.thumb"
    /// The height of a thumbnail for the choice.
    static func side(_ choice: String) -> CGFloat { choice == "huge" ? 160 : choice == "large" ? 100 : 52 }
}

struct ManageThumbSizeMenu: ToolbarContent {
    @AppStorage(ManageThumbSize.key) private var size = "list"

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Photo size", selection: $size) {
                    Text("List").tag("list"); Text("Large").tag("large"); Text("Larger").tag("huge")
                }
            } label: { Image(systemName: "arrow.up.left.and.arrow.down.right.square") }
                .accessibilityLabel("Photo size")
        }
    }
}
