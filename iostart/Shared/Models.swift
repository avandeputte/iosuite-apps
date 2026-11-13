import Foundation

/// A folder or a link of the bookmark tree, as the start page's sync API (`/dav/ext`) sends it.
struct Node: Codable, Identifiable, Hashable {
    var id: Int
    var folder: Bool
    var title: String
    var url: String?
    var children: [Node]?

    var kids: [Node] { children ?? [] }
    var link: URL? { url.flatMap { URL(string: $0) } }
    var host: String? {
        guard let h = link?.host else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
    /// What a row shows: the name, or what stands in for a missing one.
    var name: String {
        if !title.isEmpty { return title }
        return folder ? "Untitled folder" : (host ?? url ?? "Untitled")
    }
}

/// The tree with the revision it was read at.
struct TreeState: Codable {
    var rev: Int
    var tree: [Node]
}

/// The answer to a sync: the tree after the changes, and the ids given to what was made.
struct SyncResult: Codable {
    var rev: Int
    var tree: [Node]
    var ids: [String: Int]?
}

/// Who is signed in, and whether they may change the bookmarks.
struct Hello: Codable {
    var user: String
    var displayName: String
    var canWrite: Bool
    var rev: Int
    var version: String
}

/// One change sent to `/dav/ext/sync` (see app/bookmarkext.py). A missing `parent` is the top level.
struct Op: Encodable {
    var op: String
    var id: Int?
    var parent: Int?
    var folder: Bool?
    var title: String?
    var url: String?
    var ids: [Int]?

    static func create(parent: Int?, folder: Bool, title: String, url: String? = nil) -> Op {
        Op(op: "create", parent: parent, folder: folder, title: title, url: url)
    }
    static func update(_ id: Int, title: String? = nil, url: String? = nil) -> Op {
        Op(op: "update", id: id, title: title, url: url)
    }
    /// The children of `parent` named in `ids`, in that order; one named from elsewhere moves in.
    static func order(parent: Int?, ids: [Int]) -> Op {
        Op(op: "order", parent: parent, ids: ids)
    }
    static func delete(_ id: Int) -> Op {
        Op(op: "delete", id: id)
    }
}

/// A folder in a flat list, with how deep it sits.
struct FolderEntry: Identifiable {
    var node: Node
    var depth: Int
    var id: Int { node.id }
}

/// A link found by a search, with the folders above it.
struct Found: Identifiable {
    var node: Node
    var path: String
    var id: Int { node.id }
}

extension Array where Element == Node {
    func node(_ id: Int) -> Node? {
        for n in self {
            if n.id == id { return n }
            if let hit = n.children?.node(id) { return hit }
        }
        return nil
    }

    /// The children of a folder (nil: the top level).
    func children(of id: Int?) -> [Node] {
        guard let id else { return self }
        return node(id)?.kids ?? []
    }

    /// The folder a node sits in: `.some(nil)` at the top level, `nil` when the node is not in the tree.
    func parent(of id: Int, under: Int? = nil) -> Int?? {
        for n in self {
            if n.id == id { return .some(under) }
            if let kids = n.children, let hit = kids.parent(of: id, under: n.id) { return .some(hit) }
        }
        return nil
    }

    /// Changes the children of a folder (nil: the top level) in place. False when the folder is gone.
    @discardableResult
    mutating func change(childrenOf id: Int?, _ body: (inout [Node]) -> Void) -> Bool {
        guard let id else { body(&self); return true }
        for i in indices {
            if self[i].id == id {
                var kids = self[i].kids
                body(&kids)
                self[i].children = kids
                return true
            }
            if var kids = self[i].children, kids.change(childrenOf: id, body) {
                self[i].children = kids
                return true
            }
        }
        return false
    }

    /// Every folder, top to bottom, leaving out `without` and what is in it (a folder cannot move into itself).
    func folders(without: Int? = nil, depth: Int = 0) -> [FolderEntry] {
        var out: [FolderEntry] = []
        for n in self where n.folder && n.id != without {
            out.append(FolderEntry(node: n, depth: depth))
            out += n.kids.folders(without: without, depth: depth + 1)
        }
        return out
    }

    /// The links whose name or address holds every word of `query`.
    func search(_ query: String, path: [String] = []) -> [Found] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var out: [Found] = []
        for n in self {
            if n.folder {
                out += n.kids.search(query, path: path + [n.name])
            } else {
                let hay = (n.title + " " + (n.url ?? "")).lowercased()
                if words.allSatisfy({ hay.contains($0) }) {
                    out.append(Found(node: n, path: path.joined(separator: " › ")))
                }
            }
        }
        return out
    }

    var linkCount: Int { reduce(0) { $0 + ($1.folder ? $1.kids.linkCount : 1) } }
}

/// An address as typed: `example.com` becomes `https://example.com`.
func tidyAddress(_ typed: String) -> String {
    let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty || t.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil { return t }
    return "https://" + t
}
