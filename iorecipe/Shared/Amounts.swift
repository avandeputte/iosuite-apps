import Foundation

/// Amounts for another number of servings, the way ioRecipe's page does it (iorecipe/static/app.js): the amount a
/// line begins with (2, 1.5, 1,5, 1/2, 1 1/2, ½, 1½, 2-3) is multiplied; a line that begins with none stays.
enum Amounts {
    static let factors: [Double] = [0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75, 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]

    private static let fracs: [Character: Double] = ["¼": 0.25, "½": 0.5, "¾": 0.75, "⅓": 1.0 / 3, "⅔": 2.0 / 3,
                                                     "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875]
    private static let glyphs = "¼½¾⅓⅔⅛⅜⅝⅞"
    private static let num = "(?:\\d+\\s+\\d+\\s*/\\s*\\d+|\\d+\\s*/\\s*\\d+|\\d+(?:[.,]\\d+)?(?:\\s*[\(glyphs)])?|[\(glyphs)])"
    private static let amount = try! NSRegularExpression(
        pattern: "^(\\s*)(\(num))(?:(\\s*(?:-|–|to|tot|à|a|bis|or|of|ou)\\s*)(\(num)))?", options: [.caseInsensitive])
    private static let metric = try! NSRegularExpression(
        pattern: "^\\s*(?:g|gr|gram|grams|kg|mg|ml|cl|dl|l|liter|litre|liters|litres|cm|mm)\\b", options: [.caseInsensitive])
    private static let mixed = try! NSRegularExpression(pattern: "^(\\d+)\\s+(\\d+)\\s*/\\s*(\\d+)$")
    private static let simple = try! NSRegularExpression(pattern: "^(\\d+)\\s*/\\s*(\\d+)$")
    private static let glyph = try! NSRegularExpression(pattern: "^(\\d+(?:[.,]\\d+)?)?\\s*([\(glyphs)])$")

    /// A line that ends with a colon is a heading ("For the icing:").
    static func isHeading(_ line: String) -> Bool { line.hasSuffix(":") && line.count < 80 }

    static func hasAmount(_ line: String) -> Bool {
        amount.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    static func name(_ f: Double) -> String {
        if let g = fracs.first(where: { abs($0.value - f) < 0.01 }) { return "× \(g.key)" }
        return "× " + (f == f.rounded() ? String(Int(f)) : String(f))
    }

    private struct Read {
        var value: Double
        var decimal = false
    }

    private static func groups(_ re: NSRegularExpression, _ s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }

    private static func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }

    private static func read(_ text: String) -> Read {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let g = groups(mixed, t), let a = g[1], let b = g[2], let c = g[3], number(c) != 0 {
            return Read(value: number(a) + number(b) / number(c))
        }
        if let g = groups(simple, t), let a = g[1], let b = g[2], number(b) != 0 { return Read(value: number(a) / number(b)) }
        if let g = groups(glyph, t), let f = g[2]?.first.flatMap({ fracs[$0] }) { return Read(value: (g[1].map(number) ?? 0) + f) }
        return Read(value: number(t), decimal: t.contains(".") || t.contains(","))
    }

    private static func show(_ v: Double, _ a: Read, metric: Bool, comma: Bool) -> String {
        guard v > 0, v.isFinite else { return "0" }
        let whole = (v + 1e-9).rounded(.down), part = v - whole
        if part < 0.02 { return String(Int(whole)) }
        if part > 0.98 { return String(Int(whole) + 1) }
        if !metric, !a.decimal, v < 100, let g = fracs.first(where: { abs($0.value - part) < 0.04 }) {
            return whole > 0 ? "\(Int(whole)) \(g.key)" : String(g.key)
        }
        var s = String(format: v < 10 ? "%.2f" : v < 100 ? "%.1f" : "%.0f", locale: Locale(identifier: "en_US_POSIX"), v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return comma ? s.replacingOccurrences(of: ".", with: ",") : s
    }

    /// The line for f times the recipe. comma: decimals are written with a comma (as the recipe does).
    static func scale(_ line: String, by f: Double, comma: Bool = false) -> String {
        guard f != 1, let g = groups(amount, line), let all = g[0], let lead = g[1], let first = g[2] else { return line }
        let rest = String(line.dropFirst(all.count))
        let isMetric = metric.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil
        func one(_ t: String) -> String { let r = read(t); return show(r.value * f, r, metric: isMetric, comma: comma) }
        var out = lead + one(first)
        if let sep = g[3], let second = g[4] { out += sep + one(second) }
        return out + rest
    }

    /// Whether the recipe writes its decimals with a comma (1,5 dl).
    static func usesComma(_ lines: [String]) -> Bool {
        lines.contains { $0.range(of: "^\\s*\\d+,\\d", options: .regularExpression) != nil }
    }
}
