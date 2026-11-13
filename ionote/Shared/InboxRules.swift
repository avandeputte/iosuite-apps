import Foundation

/// A rule for what the Mac Inbox does with a new copy or screenshot: save it as a note straight away (into a folder,
/// with tags) or leave it out. The first enabled rule that matches wins; no match: it goes into the Inbox as before.
struct InboxRule: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case any, text, image, screenshot
        var id: Self { self }
        var label: String {
            switch self {
            case .any: return "Anything"
            case .text: return "Text"
            case .image: return "Copied pictures"
            case .screenshot: return "Screenshots"
            }
        }
    }

    enum Action: String, Codable, CaseIterable, Identifiable {
        case saveAsNote, skip
        var id: Self { self }
        var label: String { self == .saveAsNote ? "Save as a note" : "Leave out of the Inbox" }
    }

    var id = UUID().uuidString
    var enabled = true
    /// Part of the name of the app it was copied from ("" = any app).
    var app = ""
    var kind: Kind = .any
    /// Text the copy contains ("" = any text; text copies only).
    var contains = ""
    var action: Action = .saveAsNote
    var folderID: String?
    /// Tags, separated by commas or spaces.
    var tags = ""

    var tagList: [String] {
        tags.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// A short description for the list in Settings.
    var summary: String {
        var parts: [String] = [kind.label]
        if !app.isEmpty { parts.append("from apps named “\(app)”") }
        if !contains.isEmpty { parts.append("containing “\(contains)”") }
        return parts.joined(separator: " ")
    }

    func matches(kind itemKind: InboxItem.Kind, text: String, source: String, sourceApp: String?) -> Bool {
        guard enabled else { return false }
        switch kind {
        case .any: break
        case .text: if itemKind != .text { return false }
        case .image: if itemKind != .image || source == "screenshot" { return false }
        case .screenshot: if source != "screenshot" { return false }
        }
        if !app.isEmpty {
            guard let sourceApp, sourceApp.localizedCaseInsensitiveContains(app) else { return false }
        }
        if !contains.isEmpty {
            guard itemKind == .text, text.localizedCaseInsensitiveContains(contains) else { return false }
        }
        return true
    }
}

enum InboxRules {
    static var all: [InboxRule] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Prefs.inboxRules),
                  let rules = try? JSONDecoder().decode([InboxRule].self, from: data) else { return [] }
            return rules
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: Prefs.inboxRules) }
        }
    }

    static func match(kind: InboxItem.Kind, text: String, source: String, sourceApp: String?) -> InboxRule? {
        all.first { $0.matches(kind: kind, text: text, source: source, sourceApp: sourceApp) }
    }
}
