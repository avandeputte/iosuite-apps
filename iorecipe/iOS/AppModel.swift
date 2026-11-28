import SwiftUI
import UIKit

/// What the library shows: which recipes, and in what order.
struct Filter: Equatable {
    enum Scope: String, CaseIterable, Identifiable {
        case all, family, mine, favourites
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .family: return "Family"
            case .mine: return "Mine"
            case .favourites: return "Favourites"
            }
        }
    }
    enum Sort: String, CaseIterable, Identifiable {
        case title, new, rating
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title: return "By title"
            case .new: return "Newest first"
            case .rating: return "Best rated first"
            }
        }
    }
    var scope = Scope.all
    var sort = Sort.title
    var tag: String?
    var book: Int?
    var search = ""

    /// The plain list: what is kept for a start without a connection.
    var isPlain: Bool { scope == .all && sort == .title && tag == nil && book == nil && search.isEmpty }
}

/// The signed-in account and the recipes, as the server has them; what it said last is kept on disk and shown when
/// it cannot be reached.
@MainActor
final class AppModel: ObservableObject {
    @Published var credential: DeviceCredential?
    @Published var me: Me?
    @Published var filter = Filter()
    @Published var recipes: [Recipe] = []
    @Published var counts = Counts()
    @Published var tags: [TagCount] = []
    @Published var books: [Book] = []
    @Published var loaded = false
    @Published var offline = false
    @Published var problem: String?
    @Published var showSettings = false
    /// A recipe to open: one just added or imported.
    @Published var opening: Int?
    @Published var keepAwake: Bool {
        didSet { Shared.defaults.set(keepAwake, forKey: "keepAwake") }
    }

    private var asked = 0

    init() {
        keepAwake = Shared.defaults.object(forKey: "keepAwake") as? Bool ?? true
        credential = Account.load()
        if credential != nil {
            me = Cache.read("me")
            if let kept: Listing = Cache.read("recipes") { take(kept) }
        }
    }

    var api: API? { credential.map(API.init(credential:)) }
    /// Whether this account may keep a recipe somewhere: the family's (editors) or its own (members).
    var mayAdd: Bool { me.map { $0.canWrite || $0.isMember } ?? false }
    var mayAddFamily: Bool { me?.canWrite ?? false }
    var mayAddOwn: Bool { me?.isMember ?? false }

    private func take(_ l: Listing) {
        recipes = l.items
        counts = l.counts
        tags = l.tags
        books = l.books
        loaded = true
    }

    func failed(_ error: Error, quiet: Bool = false) {
        if case APIError.signedOut = error {
            forget()
            problem = error.localizedDescription
        } else if let e = error as? APIError, e.isOffline {
            offline = true
            if !quiet { problem = error.localizedDescription }
        } else if !quiet {
            problem = error.localizedDescription
        }
    }

    func signedIn(_ c: DeviceCredential) async {
        credential = c
        await refresh(quiet: false)
    }

    /// The recipes the filter asks for, as the server has them now. Quiet: a failure leaves what is shown.
    func refresh(quiet: Bool = true) async {
        guard let api else { return }
        asked += 1
        let mine = asked, f = filter
        do {
            let l = try await api.recipes(q: f.search.trimmingCharacters(in: .whitespaces), tag: f.tag,
                                          scope: f.scope == .all ? nil : f.scope.rawValue, book: f.book,
                                          sort: f.sort == .title ? nil : f.sort.rawValue)
            guard mine == asked else { return }  // an older answer, after a newer question
            take(l)
            offline = false
            if f.isPlain { Cache.write("recipes", l) }
            if let m = try? await api.me() {
                me = m
                Cache.write("me", m)
            }
        } catch {
            guard mine == asked else { return }
            failed(error, quiet: quiet)
        }
    }

    /// A recipe changed here: its card follows without asking the server for the whole list.
    func changed(_ r: Recipe) {
        if let i = recipes.firstIndex(where: { $0.id == r.id }) { recipes[i] = r }
        Cache.write("recipe-\(r.id)", r)
    }

    func signOut() {
        if let c = credential { Task { await DeviceSignIn.signOut(c) } }
        forget()
    }

    private func forget() {
        Account.clear()
        credential = nil
        me = nil
        recipes = []
        loaded = false
        filter = Filter()
    }
}

/// What the server said last, as files in the caches folder.
enum Cache {
    private static func file(_ name: String) -> URL { Shared.cacheFolder.appendingPathComponent(name + ".json") }

    static func read<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: file(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ name: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: file(name), options: .atomic)
    }
}
