import Foundation

/// The web search the address bar uses for what is not an address: the same choices as the start page's search box.
enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, startpage, ecosia, kagi

    var id: String { rawValue }

    var name: String {
        switch self {
        case .duckduckgo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        case .startpage: return "Startpage"
        case .ecosia: return "Ecosia"
        case .kagi: return "Kagi"
        }
    }

    private var base: String {
        switch self {
        case .duckduckgo: return "https://duckduckgo.com/?q="
        case .google: return "https://www.google.com/search?q="
        case .bing: return "https://www.bing.com/search?q="
        case .startpage: return "https://www.startpage.com/do/search?q="
        case .ecosia: return "https://www.ecosia.org/search?q="
        case .kagi: return "https://kagi.com/search?q="
        }
    }

    func url(for query: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let q = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: base + q)
    }
}

/// What is typed in the address bar, as the page to open: an address as it is, a bare name with https:// (http://
/// for a machine at home), anything else as a web search.
enum WebAddress {
    static func destination(for typed: String, engine: SearchEngine) -> URL? {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil || t.lowercased().hasPrefix("about:") {
            return URL(string: t) ?? engine.url(for: t)
        }
        if looksLikeHost(t), let url = URL(string: (isLocal(t) ? "http://" : "https://") + t), url.host != nil {
            return url
        }
        return engine.url(for: t)
    }

    /// No spaces, and a name with a dot in it, `localhost`, or an IP address, with or without a port and a path.
    private static func looksLikeHost(_ t: String) -> Bool {
        if t.contains(where: { $0.isWhitespace }) { return false }
        if t.contains("@") && !t.contains("/") { return false }  // an email address: search for it
        let host = hostPart(t)
        if host.isEmpty { return false }
        if host == "localhost" || isIPv4(host) { return true }
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return false }
        // a top-level name of letters: "example.com", "nas.lan"; not "3.14" or "v1.2"
        guard let top = host.split(separator: ".").last else { return false }
        return top.count >= 2 && top.allSatisfy { $0.isLetter }
    }

    private static func hostPart(_ t: String) -> String {
        var s = t
        if let cut = s.firstIndex(where: { "/?#".contains($0) }) { s = String(s[..<cut]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.lastIndex(of: ":"), s[s.index(after: colon)...].allSatisfy({ $0.isNumber }) { s = String(s[..<colon]) }
        return s.lowercased()
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in !p.isEmpty && p.count <= 3 && p.allSatisfy { $0.isNumber } && (Int(p) ?? 256) <= 255 }
    }

    /// A machine on the home network, which seldom has a certificate.
    private static func isLocal(_ t: String) -> Bool {
        let host = hostPart(t)
        return host == "localhost" || isIPv4(host) || [".local", ".lan", ".home", ".internal", ".home.arpa"].contains { host.hasSuffix($0) }
    }

    /// The site of a page, for the address bar at rest: "example.com".
    static func site(_ url: URL?) -> String? {
        guard let h = url?.host else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}
