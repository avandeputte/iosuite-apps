import AppIntents
import Foundation

// The things the Shortcuts actions and the widgets' settings pick from. Built into the app and the widget extension.

/// What an action says when it cannot go on.
struct IntentProblem: Error, CustomLocalizedStringResourceConvertible {
    var message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }

    static let signedOut = IntentProblem(message: "Open ioStart and sign in to your start page first.")

    /// An error of the start page, as it should be said.
    static func from(_ error: Error) -> IntentProblem {
        if let p = error as? IntentProblem { return p }
        return IntentProblem(message: APIError.told(error))
    }
}

enum SuiteAccess {
    /// The start page's API as this phone is signed in to it.
    static func api() throws -> API {
        guard let account = Account.load() else { throw IntentProblem.signedOut }
        return API(account: account)
    }

    /// Runs a call; errors become sayable.
    static func run<T>(_ body: (API) async throws -> T) async throws -> T {
        let api = try api()
        do {
            return try await body(api)
        } catch {
            throw IntentProblem.from(error)
        }
    }
}

// MARK: bookmarks

/// A link of the bookmark tree, from the tree the app keeps in the app group.
struct BookmarkEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "Bookmark", numericFormat: "\(placeholder: .int) bookmarks")
    static var defaultQuery = BookmarkQuery()

    var id: Int
    var title: String
    var url: String
    var path: String

    var displayRepresentation: DisplayRepresentation {
        let host = URL(string: url)?.host ?? url
        return DisplayRepresentation(title: "\(title)", subtitle: path.isEmpty ? "\(host)" : "\(path) · \(host)")
    }

    init(id: Int, title: String, url: String, path: String) {
        self.id = id; self.title = title; self.url = url; self.path = path
    }

    init(_ found: Found) {
        self.init(id: found.node.id, title: found.node.name, url: found.node.url ?? "", path: found.path)
    }
}

struct BookmarkQuery: EntityStringQuery {
    /// Every link of the kept tree, top to bottom, with the folders above it.
    static func all() -> [BookmarkEntity] {
        func walk(_ nodes: [Node], _ path: [String]) -> [BookmarkEntity] {
            nodes.flatMap { n -> [BookmarkEntity] in
                if n.folder { return walk(n.kids, path + [n.name]) }
                guard let url = n.url, !url.isEmpty else { return [] }
                return [BookmarkEntity(id: n.id, title: n.name, url: url, path: path.joined(separator: " › "))]
            }
        }
        return walk(TreeCache.load()?.tree ?? [], [])
    }

    func entities(for identifiers: [Int]) async throws -> [BookmarkEntity] {
        let all = Dictionary(BookmarkQuery.all().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return identifiers.compactMap { all[$0] }
    }

    func entities(matching string: String) async throws -> [BookmarkEntity] {
        (TreeCache.load()?.tree ?? []).search(string).filter { $0.node.url?.isEmpty == false }.map(BookmarkEntity.init)
    }

    func suggestedEntities() async throws -> [BookmarkEntity] {
        BookmarkQuery.all()
    }
}

// MARK: task lists and calendars

/// A list of ioTask a task can go to.
struct TaskListEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "List"
    static var defaultQuery = TaskListQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct TaskListQuery: EntityQuery {
    static func all() async throws -> [TaskListEntity] {
        try await SuiteAccess.run { try await $0.calendars() }.lists?.compactMap { e in
            e.id.map { TaskListEntity(id: $0.description, name: e.name ?? $0.description) }
        } ?? []
    }

    func entities(for identifiers: [String]) async throws -> [TaskListEntity] {
        let all = (try? await TaskListQuery.all()) ?? []
        return identifiers.map { id in all.first { $0.id == id } ?? TaskListEntity(id: id, name: id) }
    }

    func suggestedEntities() async throws -> [TaskListEntity] { try await TaskListQuery.all() }
}

/// A calendar of ioCalendar an event can go to.
struct CalendarEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Calendar"
    static var defaultQuery = CalendarQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct CalendarQuery: EntityQuery {
    static func all() async throws -> [CalendarEntity] {
        try await SuiteAccess.run { try await $0.calendars() }.calendars?.compactMap { e in
            e.id.map { CalendarEntity(id: $0.description, name: e.name ?? $0.description) }
        } ?? []
    }

    func entities(for identifiers: [String]) async throws -> [CalendarEntity] {
        let all = (try? await CalendarQuery.all()) ?? []
        return identifiers.map { id in all.first { $0.id == id } ?? CalendarEntity(id: id, name: id) }
    }

    func suggestedEntities() async throws -> [CalendarEntity] { try await CalendarQuery.all() }
}
