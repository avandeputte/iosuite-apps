import Foundation

/// A recipe as the server gives it: in a list without its ingredients, steps, notes and photos; alone with them.
struct Recipe: Codable, Identifiable, Hashable {
    struct Photo: Codable, Identifiable, Hashable {
        var id: Int
        var url: String
        /// The step it is the picture of (its place in steps, from 0); nil: one of the recipe's own.
        var step: Int?
        var width: Int?
        var height: Int?
    }

    var id: Int
    var title: String
    var description: String?
    var family: Bool
    /// What it makes, as written: "4", "24 cookies".
    var servings: String?
    var prepMinutes: Int?
    var cookMinutes: Int?
    var totalMinutes: Int?
    var tags: [String]
    var sourceName: String?
    /// The picture its card shows, relative to the app's address ("api/recipes/2/photos/2").
    var photo: String?
    var favourite: Bool
    var rating: Int?
    var ratingAverage: Double?
    var ratingCount: Int
    var writable: Bool
    var updated: String?

    var ingredients: [String]?
    var steps: [String]?
    var notes: String?
    var sourceUrl: String?
    var photos: [Photo]?
    var books: [Int]?

    /// "30 min · Serves 4"
    var meta: String {
        var parts: [String] = []
        if let m = totalMinutes, m > 0 { parts.append(Recipe.minutes(m)) }
        if let s = servings, !s.isEmpty { parts.append(Recipe.makes(s)) }
        return parts.joined(separator: " · ")
    }

    static func minutes(_ m: Int) -> String {
        m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    static func makes(_ s: String) -> String {
        s.allSatisfy(\.isNumber) ? "Serves \(s)" : s
    }
}

struct Book: Codable, Identifiable, Hashable {
    var id: Int
    var name: String
    var description: String?
    var family: Bool
    var writable: Bool
    var count: Int?
}

struct TagCount: Codable, Hashable {
    var tag: String
    var count: Int
}

struct Counts: Codable, Hashable {
    var all = 0
    var family = 0
    var mine = 0
    var favourites = 0
}

/// GET /api/recipes: the recipes asked for, with what is around them.
struct Listing: Codable {
    var items: [Recipe]
    var counts: Counts
    var tags: [TagCount]
    var books: [Book]
}

/// GET /api/auth/me: who is signed in and what they may do here.
struct Me: Codable, Equatable {
    struct User: Codable, Equatable {
        var name: String
        var displayName: String?
    }
    var user: User?
    /// Editors and admins: they change the family's recipes.
    var canWrite: Bool
    /// Members and more: they keep recipes of their own.
    var isMember: Bool
}

/// The fields of a recipe as the form has them and as POST and PATCH /api/recipes take them; an import from pasted
/// text or a photo gives one as a draft.
struct Draft: Codable, Equatable {
    var title: String?
    var description: String?
    var servings: String?
    var prepMinutes: Int?
    var cookMinutes: Int?
    var totalMinutes: Int?
    var ingredients: [String]?
    var steps: [String]?
    var notes: String?
    var tags: [String]?
    var sourceUrl: String?
    var sourceName: String?
    var family: Bool?
}

struct DraftAnswer: Codable {
    var draft: Draft
}

/// GET /api/import: what this server can import from.
struct ImportWays: Codable {
    var photo: Bool
}

struct Done: Codable {
    var ok: Bool?
}
