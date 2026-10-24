import Foundation

/// Which folder in iopix the uploads go to: one of the server's date layouts, a folder pattern of your own
/// (with the date the photo was taken in it), or one fixed folder. The server creates missing folders.
struct Destination: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case layout   // one of iopix's own layouts (2026/202610, 2026/10, ...)
        case pattern  // your own, e.g. Phone/{yyyy}-{mm}
        case folder   // always the same folder, e.g. Upload
    }

    var kind: Kind = .layout
    var layout = "year-yearmonth"
    var pattern = "{yyyy}/{yyyy}{mm}"
    var folder = "Upload"

    static var current: Destination {
        get {
            guard let data = AppConfig.defaults.data(forKey: "destination"),
                  let d = try? JSONDecoder().decode(Destination.self, from: data) else { return Destination() }
            return d
        }
        set { AppConfig.defaults.set(try? JSONEncoder().encode(newValue), forKey: "destination") }
    }

    /// Needs a server that takes folder patterns (newer than the fixed layouts).
    var needsPatterns: Bool { kind != .layout }

    /// What goes with the import request.
    var runFields: [String: Any] {
        switch kind {
        case .layout: return ["layout": layout]
        case .pattern: return ["pattern": Self.clean(pattern).isEmpty ? "{yyyy}/{yyyy}{mm}" : Self.clean(pattern)]
        case .folder: return ["pattern": Self.clean(folder).isEmpty ? "Upload" : Self.clean(folder)]
        }
    }

    /// The folder a photo taken on `date` goes to, for showing in settings (the server decides for real).
    func example(_ date: Date = Date(), layouts: [ServerLayout] = []) -> String {
        let text: String
        switch kind {
        case .layout: text = layouts.first { $0.key == layout }?.pattern ?? "{yyyy}/{yyyy}{mm}"
        case .pattern: text = Self.clean(pattern)
        case .folder: return Self.clean(folder)
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return text.replacingOccurrences(of: "{yyyy}", with: String(format: "%04d", c.year ?? 0))
            .replacingOccurrences(of: "{mm}", with: String(format: "%02d", c.month ?? 0))
            .replacingOccurrences(of: "{dd}", with: String(format: "%02d", c.day ?? 0))
    }

    /// Spaces and slashes at the ends trimmed, doubled slashes folded.
    static func clean(_ s: String) -> String {
        s.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "/")
    }
}

/// One of the folder layouts the server offers.
struct ServerLayout: Identifiable, Equatable {
    let key: String
    let pattern: String
    let example: String
    var id: String { key }
}
