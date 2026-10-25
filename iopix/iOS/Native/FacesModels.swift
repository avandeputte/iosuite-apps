import SwiftUI

/// A tag from the library summary, with what the People and Faces screens need: its full path (People/Yu/Carissa
/// Yu), whether it is a person, and whether other tags sit under it.
struct FacesTag: Identifiable, Hashable {
    let id: Int
    let parent: Int?
    let name: String
    let full: String
    let isPerson: Bool
    let own: Int        // photos tagged with it directly
    let all: Int        // with its sub-tags
    let icon: Int?
    let cover: Int?
    var hasKids = false

    /// As the shared face picture view wants it.
    var person: Person { Person(id: id, name: name, count: own, face: nil, all: all, icon: icon, cover: cover) }

    /// A person's family: the tag above them under People (People/Yu/Carissa Yu gives Yu).
    var family: String? {
        let parts = full.split(separator: "/").map(String.init)
        return parts.first == "People" && parts.count > 2 ? parts[parts.count - 2] : nil
    }
}

/// A face rectangle in a photo, as the face queues list it.
struct FaceItem: Identifiable, Hashable {
    let photo: Int
    let tag: Int?
    let name: String?
    let x: Int, y: Int, w: Int, h: Int
    let ts: Double
    let file: String?
    var suggest: FaceSuggestion?

    var id: String { "\(photo):\(x):\(y):\(w):\(h)" }
    var crop: String { "facecrop/\(photo)/\(x)/\(y)/\(w)/\(h).jpg" }

    init?(_ d: [String: Any]) {
        func int(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        guard let p = int("photo"), let x = int("x"), let y = int("y"), let w = int("w"), let h = int("h") else { return nil }
        photo = p; self.x = x; self.y = y; self.w = w; self.h = h
        tag = int("tag"); name = d["name"] as? String
        ts = (d["ts"] as? NSNumber)?.doubleValue ?? 0
        file = d["file"] as? String
        suggest = FaceSuggestion(d["suggest"])
    }

    /// One change to this face for /api/faces/batch.
    func op(_ op: String, tag: Int? = nil) -> [String: Any] {
        var o: [String: Any] = ["op": op, "image": photo, "rect": [x, y, w, h]]
        if let tag { o["tag"] = tag }
        return o
    }
}

/// iopix's own "looks like" guess for a face or a group of look-alikes.
struct FaceSuggestion: Hashable {
    let tag: Int, name: String, score: Double
    init?(_ any: Any?) {
        guard let d = any as? [String: Any], let t = (d["tag"] as? NSNumber)?.intValue else { return nil }
        tag = t; name = d["name"] as? String ?? ""; score = (d["score"] as? NSNumber)?.doubleValue ?? 0
    }
}

/// A section of the People page (Family, Friends...), kept by iopix.
struct PeopleGroup: Identifiable, Hashable {
    let id: Int
    var name: String
    var members: [Int]
}

/// The server calls behind the People and Faces screens.
enum FacesAPI {
    private static var client: IopixClient { .shared }

    static func tags() async throws -> [FacesTag] {
        let m = try await client.json("api/meta")
        let raw = m["tags"] as? [[String: Any]] ?? []
        var list: [FacesTag] = raw.compactMap { t in
            guard let id = (t["id"] as? NSNumber)?.intValue else { return nil }
            return FacesTag(id: id, parent: (t["pid"] as? NSNumber)?.intValue, name: (t["name"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                            full: t["full"] as? String ?? "", isPerson: (t["person"] as? NSNumber)?.boolValue ?? false,
                            own: (t["n"] as? NSNumber)?.intValue ?? 0, all: (t["nAll"] as? NSNumber)?.intValue ?? 0,
                            icon: (t["icon"] as? NSNumber)?.intValue, cover: (t["cover"] as? NSNumber)?.intValue)
        }
        let parents = Set(list.compactMap(\.parent))
        for i in list.indices where parents.contains(list[i].id) { list[i].hasKids = true }
        return list
    }

    /// [photos, faces] waiting in each queue.
    static func summary() async -> [String: (photos: Int, faces: Int)] {
        guard let j = try? await client.json("api/faces/summary") else { return [:] }
        var out: [String: (Int, Int)] = [:]
        for k in ["suggested", "unknown", "ignored"] {
            let a = (j[k] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            if a.count == 2 { out[k] = (a[0], a[1]) }
        }
        return out
    }

    struct Queue {
        var total = 0
        var faces: [FaceItem] = []
        var groups: [(tag: Int, name: String, count: Int)] = []
    }

    static func queue(_ kind: String) async throws -> Queue {
        let j = try await client.json("api/faces/queue", query: [URLQueryItem(name: "kind", value: kind), URLQueryItem(name: "limit", value: "500")])
        var q = Queue()
        q.total = (j["total"] as? NSNumber)?.intValue ?? 0
        q.faces = (j["faces"] as? [[String: Any]] ?? []).compactMap(FaceItem.init)
        q.groups = (j["groups"] as? [[Any]] ?? []).compactMap { g in
            guard g.count >= 3, let t = (g[0] as? NSNumber)?.intValue else { return nil }
            return (t, g[1] as? String ?? "", (g[2] as? NSNumber)?.intValue ?? 0)
        }
        return q
    }

    struct LookAlikes {
        var groups: [(faces: [FaceItem], suggest: FaceSuggestion?)] = []
        var ungrouped: [FaceItem] = []
        var missing: [FaceItem] = []
        var available = false
        var running = false
        var done = 0, total = 0
        var people = 0
        var usable: Bool { available && (!groups.isEmpty || !missing.isEmpty || running) }
    }

    static func lookAlikes() async -> LookAlikes? {
        guard let j = try? await client.json("api/faces/groups", query: [URLQueryItem(name: "kind", value: "unknown")]) else { return nil }
        var l = LookAlikes()
        l.groups = (j["groups"] as? [[String: Any]] ?? []).map { g in
            ((g["faces"] as? [[String: Any]] ?? []).compactMap(FaceItem.init), FaceSuggestion(g["suggest"]))
        }
        l.ungrouped = (j["ungrouped"] as? [[String: Any]] ?? []).compactMap(FaceItem.init)
        l.missing = (j["missing"] as? [[String: Any]] ?? []).compactMap(FaceItem.init)
        l.available = j["available"] as? Bool ?? true
        let p = j["progress"] as? [String: Any] ?? [:]
        l.running = p["running"] as? Bool ?? false
        l.done = (p["done"] as? NSNumber)?.intValue ?? 0
        l.total = (p["total"] as? NSNumber)?.intValue ?? 0
        l.people = (j["people"] as? NSNumber)?.intValue ?? 0
        return l
    }

    /// Many face changes in one go. Returns how many failed and the first reason.
    @discardableResult
    static func batch(_ ops: [[String: Any]]) async throws -> (failed: Int, why: String?) {
        guard !ops.isEmpty else { return (0, nil) }
        let r = try await post("api/faces/batch", ["ops": ops])
        let failed = r["failed"] as? [[String: Any]] ?? []
        return (failed.count, failed.first?["error"] as? String)
    }

    /// A new person under a family (People/<family>) or the People root itself; `parent` is that tag's id (0 makes a
    /// top-level tag, so callers pass the People root when there is no family). Returns the person's tag id.
    static func createPerson(_ name: String, parent: Int?) async throws -> Int {
        let r = try await post("api/faces/person", ["name": name, "parent": parent ?? 0])
        guard let id = (r["id"] as? NSNumber)?.intValue else { throw IopixError.server("The person was not made.") }
        return id
    }

    /// The index's version (api/status), to tell when a change has been taken in.
    static func indexVersion() async -> String? { (try? await client.json("api/status"))?["version"] as? String }

    /// Waits, up to about five seconds, for the index to move past `seen`: a face change shows in the counts and
    /// lists only once the server has reindexed.
    static func awaitReindex(after seen: String?) async {
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(500))
            if let v = await indexVersion(), v != seen { return }
        }
    }

    static func nearby(_ photo: Int) async -> [Int] {
        guard let j = try? await client.json("api/faces/nearby", query: [URLQueryItem(name: "photo", value: "\(photo)")]) else { return [] }
        return (j["people"] as? [[String: Any]] ?? []).compactMap { ($0["tag"] as? NSNumber)?.intValue }
    }

    // MARK: groups

    static func groups() async -> (groups: [PeopleGroup], canEdit: Bool) {
        guard let j = try? await client.json("api/people/groups") else { return ([], false) }
        let g = (j["groups"] as? [[String: Any]] ?? []).compactMap { g -> PeopleGroup? in
            guard let id = (g["id"] as? NSNumber)?.intValue else { return nil }
            return PeopleGroup(id: id, name: g["name"] as? String ?? "", members: (g["members"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue })
        }
        return (g, j["canEdit"] as? Bool ?? false)
    }

    static func createGroup(_ name: String) async throws -> Int {
        let r = try await post("api/people/groups", ["name": name])
        return (r["id"] as? NSNumber)?.intValue ?? 0
    }

    static func updateGroup(_ id: Int, name: String? = nil, members: [Int]? = nil) async throws {
        var b: [String: Any] = [:]
        if let name { b["name"] = name }
        if let members { b["members"] = members }
        _ = try await post("api/people/groups/\(id)", b)
    }

    static func orderGroups(_ ids: [Int]) async throws { _ = try await post("api/people/groups/order", ["ids": ids]) }

    static func deleteGroup(_ id: Int) async throws {
        let (data, resp) = try await client.session.data(for: client.request("api/people/groups/\(id)", method: "DELETE"))
        _ = try client.check(data, resp)
    }

    /// Links the signed-in (admin) account to a person, or unlinks it (nil).
    static func setMe(_ person: Int?) async throws {
        _ = try await post("api/auth/person", ["person": person as Any? ?? NSNull()])
    }

    @MainActor static func thenAndNow(_ person: Int) async -> ThenNowPair? {
        guard let j = try? await client.json("api/thenandnow", query: [URLQueryItem(name: "person", value: "\(person)"), URLQueryItem(name: "n", value: "1")]) else { return nil }
        return ExploreModel.pairs(j).first
    }

    private static func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var r = client.request(path, method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await client.session.data(for: r)
        return try client.check(data, resp)
    }
}

/// A face cut out of its photo, with a check mark when it is picked.
struct FaceCell: View {
    let face: FaceItem
    var selected = false
    var selectable = false
    var caption: String?

    var body: some View {
        VStack(spacing: 3) {
            RemoteImage(path: face.crop)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
                .overlay(alignment: .topTrailing) {
                    if selectable {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(selected ? Color.accentColor : .white)
                            .background(selected ? Circle().fill(.white) : nil).shadow(radius: 2).padding(4)
                    }
                }
            if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("MMM yyyy")
        return f
    }()

    static func month(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        return monthFormatter.string(from: Date(timeIntervalSince1970: ts))
    }
}
