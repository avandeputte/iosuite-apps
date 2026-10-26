import SwiftUI

/// Everything iopix knows about one photo that the editing screens show or change (from GET /api/photo/<id>).
/// The AI-written description (caption_ai) is deliberately not read: only what a person wrote is shown or edited.
struct EditDetail: Equatable {
    struct Tag: Identifiable, Equatable, Hashable {
        let id: Int, name: String, full: String, person: Bool
    }
    struct Face: Identifiable, Equatable {
        enum Kind: String { case confirmed, suggested, unknown, ignored }
        let kind: Kind
        let tag: Int?
        let name: String?
        let x: Double, y: Double, w: Double, h: Double
        var rect: [Int] { [Int(x.rounded()), Int(y.rounded()), Int(w.rounded()), Int(h.rounded())] }
        var id: String { "\(kind.rawValue)-\(Int(x))-\(Int(y))-\(Int(w))-\(Int(h))" }
        var label: String {
            switch kind {
            case .confirmed: return name ?? "Someone"
            case .suggested: return "\(name ?? "Someone")?"
            case .unknown: return "Unknown"
            case .ignored: return "Ignored"
            }
        }
    }

    var id = 0
    var name = ""
    var width = 0.0, height = 0.0
    var video = false
    var rating = 0
    var pick = 0
    var color = 0
    var title = ""
    var caption = ""
    var taken: Date?
    var lat: Double?, lon: Double?, alt: Double?
    /// Only the town is known: how far off the position may be, in metres (the web app's "approximate").
    var accuracy: Double?
    var place: String?
    var tags: [Tag] = []
    var faces: [Face] = []
    var folderID: Int?
    var folderPath: String?
    var folderName: String?
    var edited = false

    var keywords: [Tag] { tags.filter { !$0.person } }
    var people: [Tag] { tags.filter { $0.person } }

    /// The server's dates are the camera's clock written without a zone; they are kept that way (UTC here) so
    /// what is shown and sent back is exactly what the camera said.
    static let takenFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    init() {}

    init(json d: [String: Any]) {
        func str(_ k: String) -> String? { (d[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        id = (d["id"] as? NSNumber)?.intValue ?? 0
        name = str("name") ?? ""
        width = num("w") ?? 0
        height = num("h") ?? 0
        video = ((d["video"] as? NSNumber)?.intValue ?? 0) != 0
        rating = max(0, Int(num("rating") ?? 0))
        pick = Int(num("pick") ?? 0)
        color = Int(num("color") ?? 0)
        title = str("title") ?? ""
        caption = str("caption") ?? ""   // never caption_ai
        taken = str("taken").flatMap { Self.takenFormat.date(from: String($0.prefix(19))) }
        lat = num("lat"); lon = num("lon"); alt = num("alt")
        accuracy = ((d["extra"] as? [String: Any])?["gpsAccuracy"] as? NSNumber)?.doubleValue
        place = [str("place"), str("region"), str("country")].compactMap { $0 }.joined(separator: ", ")
        if place?.isEmpty == true { place = nil }
        tags = (d["tags"] as? [[String: Any]] ?? []).compactMap { t in
            guard let id = (t["id"] as? NSNumber)?.intValue else { return nil }
            return Tag(id: id, name: t["name"] as? String ?? "", full: t["full"] as? String ?? "",
                       person: ((t["person"] as? NSNumber)?.intValue ?? 0) != 0)
        }
        func face(_ f: [String: Any], _ kind: Face.Kind?) -> Face? {
            guard let x = (f["x"] as? NSNumber)?.doubleValue, let y = (f["y"] as? NSNumber)?.doubleValue,
                  let w = (f["w"] as? NSNumber)?.doubleValue, let h = (f["h"] as? NSNumber)?.doubleValue else { return nil }
            let k = kind ?? Face.Kind(rawValue: f["kind"] as? String ?? "") ?? .unknown
            return Face(kind: k, tag: (f["tag"] as? NSNumber)?.intValue, name: f["name"] as? String, x: x, y: y, w: w, h: h)
        }
        faces = (d["faces"] as? [[String: Any]] ?? []).compactMap { face($0, .confirmed) }
            + (d["faces_other"] as? [[String: Any]] ?? []).compactMap { face($0, nil) }
        if let a = d["album"] as? [String: Any] {
            folderID = (a["id"] as? NSNumber)?.intValue
            folderPath = a["path"] as? String
            folderName = a["name"] as? String
        } else {
            folderID = (d["album_id"] as? NSNumber)?.intValue
        }
        edited = ((d["edited"] as? NSNumber)?.intValue ?? 0) != 0
    }
}

/// The server calls the editing screens make. Every change is made by the server; the app only asks.
enum EditAPI {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @discardableResult
    static func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var r = IopixClient.shared.request(path, method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await IopixClient.shared.session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 409 {
            let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw Failure(message: j?["detail"] as? String ?? "iopix can't change this right now (is digiKam open?). Try again in a moment.")
        }
        // the server says why it refuses (editing turned off): that reason, not "could not connect"
        if code == 503, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let why = j["detail"] as? String {
            throw Failure(message: why)
        }
        return try IopixClient.shared.check(data, resp)
    }

    static func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> [String: Any] {
        try await IopixClient.shared.json(path, query: query)
    }

    static func detail(_ id: Int) async throws -> EditDetail {
        EditDetail(json: try await get("api/photo/\(id)"))
    }

    /// Metadata changes (rating, pick, color, title, caption, taken, gps, add_tags, remove_tags) for photos.
    /// A list of the photos that could not be changed comes back in "failed".
    @discardableResult
    static func edit(_ ids: [Int], _ changes: [String: Any]) async throws -> [String: Any] {
        let r = try await post("api/edit", ["ids": ids, "changes": changes])
        if let failed = r["failed"] as? [[String: Any]], let first = failed.first, failed.count == ids.count {
            throw Failure(message: first["error"] as? String ?? "The change was not saved.")
        }
        return r
    }

    static func faceOp(_ op: [String: Any]) async throws {
        _ = try await post("api/faces/op", op)
    }

    static func faceOps(_ ops: [[String: Any]]) async throws {
        let r = try await post("api/faces/batch", ["ops": ops])
        if let f = (r["failed"] as? [[String: Any]])?.first { throw Failure(message: f["error"] as? String ?? "A face change failed.") }
    }

    static func takenString(_ d: Date) -> String { EditDetail.takenFormat.string(from: d) }
}

/// The library's tags, people and folders, as the editing pickers need them (one load per app run, refreshed on
/// demand after a new tag or person is made).
@MainActor
final class EditCatalog: ObservableObject {
    static let shared = EditCatalog()

    struct Entry: Identifiable, Hashable {
        let id: Int, name: String, full: String, parent: Int?, count: Int
    }

    @Published private(set) var tags: [Entry] = []      // keywords, not people, not digiKam's own (_) tags
    @Published private(set) var people: [Entry] = []    // person tags
    @Published private(set) var folders: [Entry] = []   // full = the folder's path
    @Published private(set) var recent: [Int] = []
    @Published private(set) var peopleRoot: Int?        // the People tag new people go under
    private var loaded = false

    func load(force: Bool = false) async {
        guard force || !loaded else { return }
        guard let m = try? await IopixClient.shared.json("api/meta") else { return }
        loaded = true
        var t: [Entry] = [], p: [Entry] = []
        for x in m["tags"] as? [[String: Any]] ?? [] {
            guard let id = (x["id"] as? NSNumber)?.intValue else { continue }
            let name = (x["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let full = x["full"] as? String ?? name
            let e = Entry(id: id, name: name, full: full, parent: (x["pid"] as? NSNumber)?.intValue, count: (x["nAll"] as? NSNumber)?.intValue ?? 0)
            if full == "People" { peopleRoot = id }
            if ((x["person"] as? NSNumber)?.intValue ?? 0) != 0 { p.append(e) }
            else if !full.split(separator: "/").contains(where: { $0.hasPrefix("_") }) { t.append(e) }
        }
        tags = t.sorted { $0.full.localizedStandardCompare($1.full) == .orderedAscending }
        people = p.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        // folders: the server's path (as the web app shows it), built from the parent chain when it has none
        let raw = (m["albums"] as? [[String: Any]] ?? []).compactMap { a -> (Int, Int?, String, Int, String?)? in
            guard let id = (a["id"] as? NSNumber)?.intValue else { return nil }
            return (id, (a["pid"] as? NSNumber)?.intValue, a["name"] as? String ?? "", (a["nAll"] as? NSNumber)?.intValue ?? 0, a["path"] as? String)
        }
        let byID = Dictionary(raw.map { ($0.0, $0) }, uniquingKeysWith: { a, _ in a })
        func path(_ id: Int) -> String {
            if let p = byID[id]?.4, !p.isEmpty { return p }
            var parts: [String] = [], cur: Int? = id, steps = 0
            while let c = cur, let f = byID[c], steps < 60 { parts.insert(f.2, at: 0); cur = f.1; steps += 1 }
            return "/" + parts.joined(separator: "/")
        }
        folders = raw.map { Entry(id: $0.0, name: $0.2, full: path($0.0), parent: $0.1, count: $0.3) }
            .sorted { $0.full.localizedStandardCompare($1.full) == .orderedAscending }
        if let mt = try? await IopixClient.shared.json("api/maintenance") {
            recent = (mt["recentTags"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        }
    }

    func noteRecent(_ ids: [Int]) async {
        guard !ids.isEmpty, let r = try? await EditAPI.post("api/tags/recent", ["ids": ids]) else { return }
        recent = (r["recent"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
    }

    func tag(_ id: Int) -> Entry? { tags.first { $0.id == id } }
    func person(_ id: Int) -> Entry? { people.first { $0.id == id } }
}

/// Whether the signed-in account may change things (an editor or admin), asked once and kept.
@MainActor
final class EditRights: ObservableObject {
    static let shared = EditRights()
    @Published private(set) var canWrite = false
    @Published private(set) var isAdmin = false
    private var asked: Date?

    func refresh() async {
        if let a = asked, Date().timeIntervalSince(a) < 60 { return }
        guard let acc = try? await IopixClient.shared.account() else { return }
        asked = Date()
        canWrite = acc.signedIn && acc.canWrite
        isAdmin = acc.isAdmin
    }
}

/// A short message shown at the bottom of an editing screen for a moment.
struct EditToast: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text {
                Text(text)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { self.text = nil }
                    }
            }
        }
    }
}

extension View {
    func editToast(_ text: Binding<String?>) -> some View { modifier(EditToast(text: text)) }
}
