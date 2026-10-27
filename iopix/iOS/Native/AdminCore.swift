import SwiftUI

/// Calls for the settings and maintenance screens: JSON in and out, the server's own error text on failure.
enum AdminAPI {
    static func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> [String: Any] {
        try await IopixClient.shared.json(path, query: query)
    }

    @discardableResult
    static func post(_ path: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        var r = IopixClient.shared.request(path, method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await IopixClient.shared.session.data(for: r)
        if data.isEmpty, let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) { return [:] }
        return try IopixClient.shared.check(data, resp)
    }

    /// A form-encoded POST (the consistency check takes the photo filters that way).
    @discardableResult
    static func postForm(_ path: String, _ items: [URLQueryItem]) async throws -> [String: Any] {
        var r = IopixClient.shared.request(path, method: "POST")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = items
        r.httpBody = Data((c.percentEncodedQuery ?? "").utf8)
        let (data, resp) = try await IopixClient.shared.session.data(for: r)
        return try IopixClient.shared.check(data, resp)
    }

    /// A file from the server (a backup, the log), saved under its own name for the share sheet.
    @MainActor
    static func download(_ path: String, fallbackName: String) async throws -> URL {
        let (tmp, resp) = try await IopixClient.shared.session.download(for: IopixClient.shared.request(path))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw IopixError.server("The server could not make the file (error \((resp as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let name = PhotoPager.filename(http) ?? fallbackName
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("admin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(name)
        try FileManager.default.moveItem(at: tmp, to: dst)
        return dst
    }
}

/// Reading loosely typed JSON without a wall of casts.
extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? {
        if let s = self[k] as? String { return s }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func int(_ k: String) -> Int? { (self[k] as? NSNumber)?.intValue ?? (self[k] as? String).flatMap(Int.init) }
    func dbl(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    func bool(_ k: String) -> Bool { (self[k] as? NSNumber)?.boolValue ?? (self[k] as? Bool) ?? false }
    func dict(_ k: String) -> [String: Any] { self[k] as? [String: Any] ?? [:] }
    func list(_ k: String) -> [[String: Any]] { self[k] as? [[String: Any]] ?? [] }
    func strings(_ k: String) -> [String] { (self[k] as? [Any] ?? []).compactMap { $0 as? String } }
}

enum AdminFormat {
    static func bytes(_ n: Double?) -> String {
        guard let n, n > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    /// A server time (seconds since 1970) as "Oct 24, 3:40 PM", or "never".
    static func when(_ t: Double?) -> String {
        guard let t, t > 0 else { return "never" }
        return Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened)
    }

    static func n(_ v: Int?) -> String { (v ?? 0).formatted() }

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? one : (many ?? one + "s"))"
    }
}

/// A short message at the bottom of a settings screen (saved, failed), gone after a few seconds.
@MainActor
final class AdminNotice: ObservableObject {
    @Published var text: String?
    @Published var isError = false
    private var hide: Task<Void, Never>?

    func say(_ t: String, error: Bool = false) {
        text = t
        isError = error
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(nanoseconds: (error ? 7 : 4) * 1_000_000_000)
            if !Task.isCancelled { text = nil }
        }
    }

    func fail(_ e: Error) { say(e.localizedDescription, error: true) }

    /// Runs a server call, saying `done` when it works and the server's reason when it doesn't.
    func run(_ done: String?, _ work: @escaping () async throws -> Void) async {
        do {
            try await work()
            if let done { say(done) }
        } catch {
            fail(error)
        }
    }
}

struct AdminNoticeBar: ViewModifier {
    @ObservedObject var notice: AdminNotice

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let t = notice.text {
                Text(t)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(notice.isError ? Color.red.opacity(0.9) : Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 20).padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { notice.text = nil }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: notice.text)
    }
}

extension View {
    func adminNotice(_ n: AdminNotice) -> some View { modifier(AdminNoticeBar(notice: n)) }
}

/// A question before something that can't be taken back (restart, delete, switch database).
struct AdminConfirm: Identifiable {
    let id = UUID()
    let title: String
    var message: String = ""
    var button: String = "Continue"
    var destructive = false
    let action: () async -> Void
}

extension View {
    func adminConfirm(_ item: Binding<AdminConfirm?>) -> some View {
        alert(item.wrappedValue?.title ?? "", isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }), presenting: item.wrappedValue) { c in
            Button("Cancel", role: .cancel) {}
            Button(c.button, role: c.destructive ? .destructive : nil) { Task { await c.action() } }
        } message: { c in
            if !c.message.isEmpty { Text(c.message) }
        }
    }
}

/// A row with a title, an explanation under it, and its control on the right or below.
struct AdminRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.body.weight(.medium))
                Spacer(minLength: 8)
                trailing()
            }
            if let detail, !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

extension AdminRow where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
        self.trailing = { EmptyView() }
    }
}

/// A progress bar with "done / total" for a background job.
struct AdminProgress: View {
    let done: Int
    let total: Int
    var label: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let label { Text(label).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("\(min(done, total).formatted()) / \(total.formatted())").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: total > 0 ? Double(min(done, total)) / Double(total) : 0)
        }
    }
}

/// Pick a person from People (to link an account to who they are).
struct AdminPersonPicker: View {
    let title: String
    let pick: (Person?) -> Void
    var allowNone = false
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                if allowNone {
                    Button("Not linked") { pick(nil); dismiss() }.foregroundStyle(.red)
                }
                ForEach(store.people.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { p in
                    Button {
                        pick(p)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            FaceImage(person: p).frame(width: 40, height: 40).clipShape(Circle())
                            Text(p.name).foregroundStyle(.primary)
                            Spacer()
                            Text(p.all.formatted()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Find a person")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { BarText("Cancel") } } }
        }
    }
}

/// A file ready to hand to the share sheet (a backup, the server log).
struct AdminSharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}
