import SwiftUI
import WebKit

/// One article, as the feed has it (cleaned by the start page): opening it marks it read. The arrows step through
/// the list it was opened from; a link in the text opens as bookmarks do (Settings).
struct ArticleView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var news: NewsModel
    @ObservedObject var list: ArticleList
    @State var id: Int

    @State private var full: Article?
    @State private var problem: String?

    private var index: Int? { list.items.firstIndex { $0.id == id } }
    private var article: Article? { index.map { list.items[$0] } ?? full }

    var body: some View {
        Group {
            if let full, full.id == id {
                ArticleText(html: ArticlePage.html(full), open: { model.open($0) })
                    .ignoresSafeArea(edges: .bottom)
            } else if let problem {
                ContentUnavailableView {
                    Label("The article is not available", systemImage: "newspaper")
                } description: {
                    Text(problem)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(article?.feed ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let article {
                    Button { Task { await list.star(article, !article.starred, account: model.account, news: news) } } label: {
                        Image(systemName: article.starred ? "star.fill" : "star")
                    }
                    .accessibilityLabel(article.starred ? "Remove the star" : "Star")
                    Menu {
                        Button { Task { await list.mark(article, read: !article.read, account: model.account, news: news) } } label: {
                            Label(article.read ? "Mark as unread" : "Mark as read", systemImage: article.read ? "circle.fill" : "checkmark.circle")
                        }
                        if let url = article.linkURL {
                            Button { model.open(url, in: .app) } label: { Label("Open here", systemImage: "rectangle.portrait.and.arrow.right") }
                            Button { model.open(url, in: .browser) } label: { Label("Open in my browser", systemImage: "safari") }
                            Button { UIPasteboard.general.url = url } label: { Label("Copy address", systemImage: "doc.on.doc") }
                            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("The article before")
                    .disabled((index ?? 0) <= 0)
                Button { step(1) } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("The next article")
                    .disabled(index.map { $0 >= list.items.count - 1 } ?? true)
                Spacer()
                if let url = article?.linkURL {
                    Button { model.open(url) } label: { Label("Open the page", systemImage: "safari").labelStyle(.titleAndIcon) }
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)  // the arrows and Open the page take the bottom of the screen
        .task(id: id) { await load() }
    }

    private func step(_ by: Int) {
        guard let i = index, list.items.indices.contains(i + by) else { return }
        id = list.items[i + by].id
    }

    private func load() async {
        guard let account = model.account else { return }
        problem = nil
        do {
            let got = try await API(account: account).article(id)
            guard got.id == id else { return }
            full = got
            if let listed = article, !listed.read { await list.mark(listed, read: true, account: account, news: news) }
        } catch {
            problem = NewsModel.told(error)
        }
    }
}

/// The page an article is shown as: its title, where and when it is from, and its text in the phone's type.
enum ArticlePage {
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func html(_ a: Article) -> String {
        let body = a.html ?? ""
        let by = [a.feed, a.author, a.date?.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.filter { !$0.isEmpty }.map(esc).joined(separator: " · ")
        // the feed's own picture on top, when its text has none
        let lead = body.range(of: "<img", options: .caseInsensitive) == nil ? a.image.map { "<p class=\"lead\"><img src=\"\(esc($0))\" alt=\"\"></p>" } ?? "" : ""
        let audio = a.audio.map { "<p><audio controls preload=\"none\" src=\"\(esc($0))\"></audio></p>" } ?? ""
        let more = a.link.map { "<p class=\"more\"><a href=\"\(esc($0))\">Open the page</a></p>" } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body { font: -apple-system-body; max-width: 44em; margin: 0 auto; padding: 14px 18px 48px; line-height: 1.5; overflow-wrap: break-word; -webkit-text-size-adjust: 100%; }
        h1 { font: -apple-system-title2; font-weight: 700; line-height: 1.25; margin: 0 0 6px; }
        .by { font: -apple-system-footnote; opacity: .6; margin: 0 0 18px; }
        img, video, iframe, svg { max-width: 100%; height: auto; border-radius: 8px; }
        .lead img { width: 100%; }
        audio { width: 100%; }
        pre { white-space: pre-wrap; font-size: .85em; }
        table { display: block; max-width: 100%; overflow-x: auto; }
        blockquote { margin: 1em 0; padding-left: 12px; border-left: 3px solid rgba(128,128,128,.4); }
        figure { margin: 1em 0; } figcaption { font: -apple-system-footnote; opacity: .6; }
        .more { margin-top: 28px; font-weight: 600; }
        </style></head><body>
        <h1>\(esc(a.title))</h1><p class="by">\(by)</p>\(audio)\(lead)\(body)\(more)
        </body></html>
        """
    }
}

/// The article's text in a web view that runs nothing: no scripts, and a tapped link goes to `open` instead.
private struct ArticleText: UIViewRepresentable {
    let html: String
    let open: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(open: open) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.open = open
        guard context.coordinator.shown != html else { return }
        context.coordinator.shown = html
        view.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var open: (URL) -> Void
        var shown: String?

        init(open: @escaping (URL) -> Void) { self.open = open }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // the article itself loads; anything tapped in it opens outside this view
            if action.navigationType == .other && action.targetFrame?.isMainFrame != false && action.request.url?.scheme == "about" {
                decisionHandler(.allow)
            } else if action.targetFrame?.isMainFrame == false {
                decisionHandler(.cancel)  // a frame inside the article: not loaded
            } else {
                if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { open(url) }
                decisionHandler(.cancel)
            }
        }
    }
}
