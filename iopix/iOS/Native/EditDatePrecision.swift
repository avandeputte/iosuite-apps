import SwiftUI

/// How much of a photo's date is known, as iopix 1.80 keeps it: exact, month and year, year only, or unknown. An
/// approximate date is saved with a placeholder day (1 January, or the 1st of the month) and shown as "1992",
/// "May 1992" or "Date unknown".
enum DateKnown: Int, CaseIterable, Identifiable {
    case exact = 0, month = 1, year = 2, unknown = 3
    var id: Int { rawValue }

    init(level: Int?) { self = DateKnown(rawValue: level ?? 0) ?? .exact }
    var level: Int? { self == .exact ? nil : rawValue }
    var apiName: String { PhotoDates.name(level) }

    var label: String {
        switch self {
        case .exact: return "Exact date"
        case .month: return "Month and year"
        case .year: return "Year only"
        case .unknown: return "Unknown"
        }
    }

    /// What saving means, in the web app's words.
    func note(many: Bool) -> String? {
        switch self {
        case .exact: return nil
        case .unknown:
            return many ? "The photos keep the dates they have, so they stay where they sort now, and are shown as “Date unknown”."
                        : "The photo keeps the date it has, so it stays where it sorts now, and is shown as “Date unknown”."
        case .month, .year:
            return "Saved as \(self == .year ? "1 January of that year" : "the 1st of that month") where a full date is required (digiKam, EXIF), with the tag “Date approximate/\(self == .year ? "Year only" : "Month and year")”; shown as \(self == .year ? "just the year" : "the month and year")."
        }
    }

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = .current  // month names in the reader's language ("May", not "M05")
        return c
    }()
    static var years: [Int] { Array((1850...(utc.component(.year, from: Date()) + 1)).reversed()) }
}

/// The year and month controls of an approximate date. `year` 0 means "each photo's own" (several photos only).
struct ApproxDateFields: View {
    let known: DateKnown
    @Binding var year: Int
    @Binding var month: Int
    var allowOwn = false

    var body: some View {
        if known == .month {
            Picker("Month", selection: $month) {
                if allowOwn && year == 0 { Text("Each photo's own").tag(0) }
                ForEach(1...12, id: \.self) { m in Text(DateKnown.utc.monthSymbols[m - 1]).tag(m) }
            }
        }
        if known == .month || known == .year {
            Picker("Year", selection: $year) {
                if allowOwn { Text("Each photo's own").tag(0) }
                ForEach(DateKnown.years, id: \.self) { y in Text(String(y)).tag(y) }
            }
        }
    }
}
