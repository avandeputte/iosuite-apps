import Foundation
import SwiftUI

/// Markdown in notes, the same subset the web app draws: # headings, **bold**, *italic*, ~~struck~~, `code`,
/// [links](https://…) and bare addresses, lists, - [ ] checklists you can tick, > quotes, ``` code blocks and ---
/// rules. A single line break stays a line break, since most notes are plain text.
enum Markdown {
    enum Block: Hashable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case item(indent: Int, marker: String, text: String)
        case task(indent: Int, done: Bool, text: String, line: Int)
        case quote(String)
        case code(String)
        case rule
    }

    /// "- [ ] text" / "1. [x] text": (indent, marker, done, text).
    static func task(_ line: String) -> (indent: Int, done: Bool, text: String)? {
        guard let m = line.firstMatch(of: #/^(\s*)([-*+]|\d+[.)])\s+\[( |x|X)\]\s?(.*)$/#) else { return nil }
        return (m.1.count, m.3 != " ", String(m.4))
    }

    static func item(_ line: String) -> (indent: Int, marker: String, text: String)? {
        guard let m = line.firstMatch(of: #/^(\s*)([-*+]|\d+[.)])\s+(.*)$/#) else { return nil }
        return (m.1.count, String(m.2), String(m.3))
    }

    private static func isFence(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("```") || t.hasPrefix("~~~")
    }

    /// "---", "***", "___" (spaces allowed between).
    private static func isRule(_ trimmed: String) -> Bool {
        let chars = trimmed.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    static func parse(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var para: [String] = []
        var quote: [String] = []
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isFence(line) {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count, !isFence(lines[i]) { code.append(lines[i]); i += 1 }
                blocks.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); i += 1; continue }
            if let m = line.firstMatch(of: #/^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/#) {
                flush()
                blocks.append(.heading(level: m.1.count, text: String(m.2)))
            } else if isRule(trimmed) {
                flush()
                blocks.append(.rule)
            } else if let m = line.firstMatch(of: #/^\s*>\s?(.*)$/#) {
                if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
                quote.append(String(m.1))
            } else if let t = task(line) {
                flush()
                blocks.append(.task(indent: t.indent / 2, done: t.done, text: t.text, line: i))
            } else if let it = item(line) {
                flush()
                blocks.append(.item(indent: it.indent / 2, marker: it.marker.first?.isNumber == true ? it.marker : "•", text: it.text))
            } else {
                if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
                para.append(line)
            }
            i += 1
        }
        flush()
        return blocks
    }

    /// The text with the box on this line ticked or not.
    static func toggleTask(_ text: String, line: Int, checked: Bool) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line), task(lines[line]) != nil,
              let r = lines[line].range(of: #"\[( |x|X)\]"#, options: .regularExpression) else { return text }
        lines[line].replaceSubrange(r, with: checked ? "[x]" : "[ ]")
        return lines.joined(separator: "\n")
    }

    /// (done, total) checklist items, code blocks left out.
    static func taskCounts(_ text: String) -> (done: Int, total: Int) {
        guard text.contains("[") else { return (0, 0) }
        var done = 0, total = 0, code = false
        for line in text.components(separatedBy: "\n") {
            if isFence(line) { code.toggle(); continue }
            if !code, let t = task(line) { total += 1; if t.done { done += 1 } }
        }
        return (done, total)
    }

    /// The text without the markup, for previews in lists.
    static func plain(_ text: String) -> String {
        guard text.contains(where: { "#*_`[~>-".contains($0) }) else { return text }
        return text.components(separatedBy: "\n").map { line -> String in
            if let t = task(line) { return (t.done ? "☑ " : "☐ ") + t.text }
            var l = line.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            for mark in ["**", "__", "~~", "`"] { l = l.replacingOccurrences(of: mark, with: "") }
            return l
        }.joined(separator: "\n")
    }

    /// One line or paragraph of inline markdown, with bare web addresses made links too.
    static func inline(_ text: String) -> AttributedString {
        var out = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let plain = String(out.characters)
        if plain.contains("://"), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let url = match.url, let r = Range(match.range, in: out), out[r].link == nil else { continue }
                out[r].link = url
            }
        }
        return out
    }

    /// A template's placeholders filled in with this device's clock: {{date}} {{time}} {{datetime}} {{weekday}}
    /// {{month}} {{year}} {{tomorrow}} {{yesterday}} (the same as the web app and the server).
    static func expand(_ text: String, now: Date = Date()) -> String {
        guard text.contains("{{") else { return text }
        let cal = Calendar.current
        func fmt(_ f: String, _ d: Date = now) -> String {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = f
            return df.string(from: d)
        }
        let values = ["date": fmt("yyyy-MM-dd"), "time": fmt("HH:mm"), "datetime": fmt("yyyy-MM-dd HH:mm"),
                      "weekday": fmt("EEEE"), "month": fmt("MMMM"), "year": fmt("yyyy"),
                      "tomorrow": fmt("yyyy-MM-dd", cal.date(byAdding: .day, value: 1, to: now) ?? now),
                      "yesterday": fmt("yyyy-MM-dd", cal.date(byAdding: .day, value: -1, to: now) ?? now)]
        var out = text
        for (key, value) in values {
            out = out.replacingOccurrences(of: #"\{\{\s*"# + key + #"\s*\}\}"#, with: value, options: [.regularExpression, .caseInsensitive])
        }
        return out
    }
}

/// A note's text drawn as Markdown. onToggle(line, checked): a checklist box was clicked (nil: boxes can't be ticked).
struct MarkdownView: View {
    let text: String
    var onToggle: ((Int, Bool) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Markdown.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: Markdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Markdown.inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        case .paragraph(let text):
            Text(Markdown.inline(text))
        case .item(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary)
                Text(Markdown.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .task(let indent, let done, let text, let line):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    onToggle?(line, !done)
                } label: {
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(done ? AnyShapeStyle(Brand.teal) : AnyShapeStyle(.secondary))
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .disabled(onToggle == nil)
                Text(Markdown.inline(text))
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .quote(let text):
            Text(Markdown.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Brand.teal).frame(width: 3) }
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}
