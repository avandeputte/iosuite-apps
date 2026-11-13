import Foundation

/// The formatting bar's commands, the same as the web app's (static/js/markdown.js, formatEdit): each one works out
/// what to replace in the text and where the selection goes after it, so the text views stay plain and ⌘Z undoes it.
/// Offsets are UTF-16 (NSRange), as NSTextView and UITextView count them. Each command toggles: bold text turns
/// plain again, a list item a plain line.
enum MarkdownFormat {
    enum Command: String, CaseIterable, Identifiable {
        case bold, italic, strike, code, link, heading, bullet, number, checklist, quote, codeBlock, rule

        var id: String { rawValue }

        /// The bar in groups, in its order.
        static let groups: [[Command]] = [[.bold, .italic, .strike, .code, .link],
                                          [.heading, .bullet, .number, .checklist, .quote],
                                          [.codeBlock, .rule]]

        var label: String {
            switch self {
            case .bold: "Bold"
            case .italic: "Italic"
            case .strike: "Strikethrough"
            case .code: "Code"
            case .link: "Link"
            case .heading: "Heading"
            case .bullet: "Bulleted List"
            case .number: "Numbered List"
            case .checklist: "Checklist"
            case .quote: "Quote"
            case .codeBlock: "Code Block"
            case .rule: "Divider"
            }
        }

        var systemImage: String {
            switch self {
            case .bold: "bold"
            case .italic: "italic"
            case .strike: "strikethrough"
            case .code: "chevron.left.forwardslash.chevron.right"
            case .link: "link"
            case .heading: "number"
            case .bullet: "list.bullet"
            case .number: "list.number"
            case .checklist: "checklist"
            case .quote: "text.quote"
            case .codeBlock: "curlybraces"
            case .rule: "minus"
            }
        }

        /// The shortcut with ⌘ (the web app's too): the key ("8" is the 8 key, also with ⇧) and whether ⇧ is held.
        var shortcut: (key: String, shift: Bool)? {
            switch self {
            case .bold: ("b", false)
            case .italic: ("i", false)
            case .strike: ("x", true)
            case .code: ("e", false)
            case .link: ("k", false)
            case .heading: ("h", true)
            case .bullet: ("8", true)
            case .number: ("7", true)
            case .checklist: ("l", true)
            case .quote: (".", true)
            case .codeBlock, .rule: nil
            }
        }

        /// "Bold (⌘B)", for tooltips.
        var help: String {
            guard let s = shortcut else { return label }
            return "\(label) (\(s.shift ? "⇧" : "")⌘\(s.key.uppercased()))"
        }
    }

    /// Replace `range` (in the text as it was) with `text`, then select `selection` (in the text after it).
    struct Edit: Equatable {
        var range: NSRange
        var text: String
        var selection: NSRange
    }

    static func edit(_ cmd: Command, text: String, selection: NSRange) -> Edit {
        let v = text as NSString
        let s = min(selection.location, v.length), e = min(selection.location + selection.length, v.length)
        switch cmd {
        case .bold: return wrap(v, s, e, "**")
        case .italic: return wrap(v, s, e, "*")
        case .strike: return wrap(v, s, e, "~~")
        case .code: return wrap(v, s, e, "`")
        case .link: return link(v, s, e)
        case .rule: return rule(v, s, e)
        case .codeBlock: return fence(v, s, e)
        case .heading, .bullet, .number, .checklist, .quote: return lines(v, s, e, cmd)
        }
    }

    /// The text with an edit made (for tests and previews).
    static func applying(_ ed: Edit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: ed.range, with: ed.text)
    }

    /// Return in a list item continues the list (a checklist with an empty box); Return on an empty item ends the
    /// list. nil: an ordinary new line.
    static func newline(text: String, selection: NSRange) -> Edit? {
        guard selection.length == 0 else { return nil }
        let v = text as NSString
        let s = min(selection.location, v.length)
        let start = lineStart(v, s)
        let line = v.substring(with: NSRange(location: start, length: s - start))
        let found: (indent: Substring, marker: Substring, content: Substring, isTask: Bool)
        if let m = line.wholeMatch(of: task) { found = (m.1, m.2, m.4, true) }
        else if let m = line.wholeMatch(of: item) { found = (m.1, m.2, m.3, false) }
        else { return nil }
        let (indent, marker, content, isTask) = found
        if content.trimmingCharacters(in: .whitespaces).isEmpty {  // an empty item: the list ends here
            return Edit(range: NSRange(location: start, length: s - start), text: "", selection: NSRange(location: start, length: 0))
        }
        var next = String(marker)
        if marker.first?.isNumber == true, let n = Int(String(marker.dropLast())), let last = marker.last { next = "\(n + 1)\(last)" }
        let ins = "\n\(indent)\(next) " + (isTask ? "[ ] " : "")
        return Edit(range: NSRange(location: s, length: 0), text: ins, selection: NSRange(location: s + len(ins), length: 0))
    }

    // MARK: - the commands

    private static let task = #/(\s*)([-*+]|\d+[.)])\s+\[( |x|X)\]\s?(.*)/#
    private static let item = #/(\s*)([-*+]|\d+[.)])\s+(.*)/#
    private static let newlineChar: unichar = 10

    private static func len(_ s: some StringProtocol) -> Int { s.utf16.count }
    private static func sub(_ v: NSString, _ a: Int, _ b: Int) -> String { v.substring(with: NSRange(location: a, length: b - a)) }
    private static func range(_ a: Int, _ b: Int) -> NSRange { NSRange(location: a, length: b - a) }

    private static func lineStart(_ v: NSString, _ s: Int) -> Int {
        guard s > 0 else { return 0 }
        let r = v.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: s))
        return r.location == NSNotFound ? 0 : r.location + 1
    }

    /// The end of the line the selection ends on (a selection ending just after a line break ends on that line).
    private static func lineEnd(_ v: NSString, _ s: Int, _ e: Int) -> Int {
        let from = e > s && v.character(at: e - 1) == newlineChar ? e - 1 : e
        let r = v.range(of: "\n", options: [], range: NSRange(location: from, length: v.length - from))
        return r.location == NSNotFound ? v.length : r.location
    }

    private static func isWord(_ c: unichar) -> Bool {
        guard let u = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(u) || c == 95 || c == 39 || c == 0x2019  // _ ' ’
    }

    /// (leading space, words, trailing space) of a line.
    private static func split(_ l: String) -> (String, String, String) {
        let ns = l as NSString
        var a = 0, b = ns.length
        while a < b, CharacterSet.whitespaces.contains(Unicode.Scalar(ns.character(at: a)) ?? " ") { a += 1 }
        while b > a, CharacterSet.whitespaces.contains(Unicode.Scalar(ns.character(at: b - 1)) ?? " ") { b -= 1 }
        return (sub(ns, 0, a), sub(ns, a, b), sub(ns, b, ns.length))
    }

    /// **bold**, *italic*, ~~struck~~, `code` around the selection (the word at the caret when nothing is selected),
    /// or taken off when it is already there. Each line of a longer selection gets its own pair.
    private static func wrap(_ v: NSString, _ s: Int, _ e: Int, _ mark: String) -> Edit {
        let n = len(mark), ch = mark.utf16.first!
        if s == e {  // the word around the caret, or an empty pair to type in
            var a = s, b = e
            while a > 0, isWord(v.character(at: a - 1)) { a -= 1 }
            while b < v.length, isWord(v.character(at: b)) { b += 1 }
            if a == b {
                if s >= n, s + n <= v.length, sub(v, s - n, s) == mark, sub(v, s, s + n) == mark {
                    return Edit(range: range(s - n, s + n), text: "", selection: NSRange(location: s - n, length: 0))
                }
                return Edit(range: NSRange(location: s, length: 0), text: mark + mark, selection: NSRange(location: s + n, length: 0))
            }
            let ed = wrap(v, a, b, mark)
            let shift = len(ed.text) - (b - a) > 0 ? n : -n  // the caret stays where it was in the word
            return Edit(range: ed.range, text: ed.text, selection: NSRange(location: s + shift, length: 0))
        }
        // a run of the mark's character next to the selection: ** for bold, an odd run (* or ***) for italic
        func run(_ t: NSString, _ i: Int, _ step: Int) -> Int {
            var k = 0, j = i
            while j >= 0, j < t.length, t.character(at: j) == ch { k += 1; j += step }
            return k
        }
        func marked(_ l: Int, _ r: Int) -> Bool {
            ch == 42 /* * */ ? (n == 2 ? l >= 2 && r >= 2 : l % 2 == 1 && r % 2 == 1) : l >= n && r >= n
        }
        if marked(run(v, s - 1, -1), run(v, e, 1)) {
            return Edit(range: range(s - n, e + n), text: sub(v, s, e), selection: range(s - n, e - n))
        }
        func inner(_ t: String) -> Bool {
            let ns = t as NSString
            let l = run(ns, 0, 1)
            return ns.length > 2 * n && l < ns.length && marked(l, run(ns, ns.length - 1, -1))
        }
        let sel = sub(v, s, e)
        let lines = sel.components(separatedBy: "\n")
        let filled = lines.map(split).filter { !$0.1.isEmpty }
        let off = !filled.isEmpty && filled.allSatisfy { inner($0.1) }
        let text = lines.map { l -> String in
            let (lead, body, tail) = split(l)
            if body.isEmpty { return l }
            let b = body as NSString
            return lead + (off ? sub(b, n, b.length - n) : mark + body + mark) + tail
        }.joined(separator: "\n")
        if lines.count == 1 {  // select the words themselves, without the marks
            let (lead, _, tail) = split(sel)
            return Edit(range: range(s, e), text: text,
                        selection: range(s + len(lead) + (off ? 0 : n), s + len(text) - len(tail) - (off ? 0 : n)))
        }
        return Edit(range: range(s, e), text: text, selection: NSRange(location: s, length: len(text)))
    }

    /// [selection](https://) with the address selected to type over; a selected address becomes [](address).
    private static func link(_ v: NSString, _ s: Int, _ e: Int) -> Edit {
        let raw = sub(v, s, e)
        let sel = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if sel.wholeMatch(of: #/(https?:\/\/|mailto:)\S+/#) != nil {
            return Edit(range: range(s, e), text: "[](\(sel))", selection: NSRange(location: s + 1, length: 0))
        }
        let label = raw.replacing(#/\n+/#, with: " ")
        let text = "[\(label)](https://)"
        if label.isEmpty { return Edit(range: range(s, e), text: text, selection: NSRange(location: s + 1, length: 0)) }
        return Edit(range: range(s, e), text: text, selection: range(s + len(label) + 3, s + len(text) - 1))
    }

    /// A --- divider on its own line, after the line the caret is on.
    private static func rule(_ v: NSString, _ s: Int, _ e: Int) -> Edit {
        let r = v.range(of: "\n", options: [], range: NSRange(location: e, length: v.length - e))
        let stop = r.location == NSNotFound ? v.length : r.location
        let before = sub(v, 0, stop)
        let lead = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ""
            : before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n"
        let tail = sub(v, stop, v.length).hasPrefix("\n") ? "" : "\n"
        let text = lead + "---\n" + tail
        return Edit(range: NSRange(location: stop, length: 0), text: text, selection: NSRange(location: stop + len(text), length: 0))
    }

    /// ``` fences around the lines the selection touches (an empty block to type in when nothing is selected), or
    /// taken off when the lines are a block already.
    private static func fence(_ v: NSString, _ s: Int, _ e: Int) -> Edit {
        let start = lineStart(v, s), stop = lineEnd(v, s, e)
        let lines = sub(v, start, stop).components(separatedBy: "\n")
        let isFence = { (l: String) in let t = l.trimmingCharacters(in: .whitespaces); return t.hasPrefix("```") || t.hasPrefix("~~~") }
        if lines.count >= 2, isFence(lines[0]), isFence(lines[lines.count - 1]) {
            let text = lines.dropFirst().dropLast().joined(separator: "\n")
            return Edit(range: range(start, stop), text: text, selection: NSRange(location: start, length: len(text)))
        }
        if s == e, lines.joined().trimmingCharacters(in: .whitespaces).isEmpty {
            return Edit(range: range(start, stop), text: "```\n\n```", selection: NSRange(location: start + 4, length: 0))
        }
        let body = lines.joined(separator: "\n")
        return Edit(range: range(start, stop), text: "```\n" + body + "\n```", selection: NSRange(location: start + 4, length: len(body)))
    }

    private static let head = #/^(\s{0,3})(#{1,6})\s+/#
    private static let quoteMark = #/^(\s*)>\s?/#
    private static let listed = #/^(\s*)([-*+]|\d+[.)])\s+(\[( |x|X)\]\s?)?/#
    private static let prefix = #/^\s*(>\s?)?(#{1,6}\s+)?(([-*+]|\d+[.)])\s+(\[( |x|X)\]\s?)?)?/#

    /// Headings, lists, checklists and quotes on every line the selection touches; the same command again takes it
    /// off (a heading goes #, ##, ###, then plain).
    private static func lines(_ v: NSString, _ s: Int, _ e: Int, _ cmd: Command) -> Edit {
        let start = lineStart(v, s), stop = lineEnd(v, s, e)
        let lines = sub(v, start, stop).components(separatedBy: "\n")
        let blank = { (l: String) in l.trimmingCharacters(in: .whitespaces).isEmpty }
        let filled = lines.filter { !blank($0) }
        let one = lines.count == 1
        func all(_ test: (String) -> Bool) -> Bool { (filled.isEmpty ? lines : filled).allSatisfy(test) }
        let isTask = { (l: String) in l.wholeMatch(of: task) != nil }
        let isBullet = { (l: String) in !isTask(l) && l.firstMatch(of: #/^\s*[-*+]\s+/#) != nil }
        let isNumber = { (l: String) in !isTask(l) && l.firstMatch(of: #/^\s*\d+[.)]\s+/#) != nil }
        let bare = { (l: String) -> String in
            l.replacing(quoteMark, maxReplacements: 1) { String($0.1) }
                .replacing(head, maxReplacements: 1) { String($0.1) }
                .replacing(listed, maxReplacements: 1) { String($0.1) }
        }
        var next: [String]
        switch cmd {
        case .heading:
            let level = (filled.first ?? lines[0]).firstMatch(of: head).map { $0.2.count } ?? 0
            let hashes = level >= 3 ? "" : String(repeating: "#", count: level + 1) + " "
            next = lines.map { l in
                guard !blank(l) || one else { return l }
                return l.replacing(head, maxReplacements: 1) { String($0.1) }
                    .replacing(#/^(\s{0,3})/#, maxReplacements: 1) { String($0.1) + hashes }
            }
        case .quote:
            let off = all { $0.firstMatch(of: quoteMark) != nil }
            next = lines.map { l in
                off ? l.replacing(quoteMark, maxReplacements: 1) { String($0.1) } : (!blank(l) || one) ? "> " + l : l
            }
        default:
            let test = cmd == .bullet ? isBullet : cmd == .number ? isNumber : isTask
            let off = all(test)
            var k = 0
            next = lines.map { l in
                if blank(l) && !one { return l }
                let indent = String(l.prefix { $0 == " " || $0 == "\t" })
                let text = String(bare(l).dropFirst(indent.count))
                if off { return indent + text }
                switch cmd {
                case .bullet: return "\(indent)- \(text)"
                case .number: k += 1; return "\(indent)\(k). \(text)"
                default:  // a checklist keeps a list's own marker
                    if isTask(l) { return l }
                    if let it = l.wholeMatch(of: item) { return "\(it.1)\(it.2) [ ] \(it.3)" }
                    return "\(indent)- [ ] \(text)"
                }
            }
        }
        let text = next.joined(separator: "\n")
        if one && s == e {  // the caret stays in the words it was in
            let p = { (l: String) in l.prefixMatch(of: prefix).map { len($0.0) } ?? 0 }
            let pos = start + max(p(text), s - start - p(lines[0]) + p(text))
            return Edit(range: range(start, stop), text: text, selection: NSRange(location: pos, length: 0))
        }
        return Edit(range: range(start, stop), text: text,
                    selection: s == e ? NSRange(location: start + len(text), length: 0) : NSRange(location: start, length: len(text)))
    }
}
