import SwiftUI
import WebKit

/// The built-in browser: one page at a time, with back, forward, share, "bookmark this" and a way out to the real one.
struct BrowserView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let start: URL
    @StateObject private var web = WebState()
    @State private var draft: Draft?

    var body: some View {
        NavigationStack {
            WebViewHost(view: web.view)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if web.loading {
                        ProgressView(value: web.progress).progressViewStyle(.linear).animation(.default, value: web.progress)
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(web.title.isEmpty ? (web.host ?? "") : web.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let host = web.host, !web.title.isEmpty {
                                Text(host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if web.loading { web.view.stopLoading() } else { web.view.reload() }
                        } label: {
                            Image(systemName: web.loading ? "xmark" : "arrow.clockwise")
                        }
                        .accessibilityLabel(web.loading ? "Stop" : "Reload")
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { web.view.goBack() } label: { Image(systemName: "chevron.backward") }
                            .disabled(!web.canGoBack).accessibilityLabel("Back")
                        Spacer()
                        Button { web.view.goForward() } label: { Image(systemName: "chevron.forward") }
                            .disabled(!web.canGoForward).accessibilityLabel("Forward")
                        Spacer()
                        ShareLink(item: web.url ?? start) { Image(systemName: "square.and.arrow.up") }
                        Spacer()
                        Button {
                            draft = Draft(folder: false, parent: nil, title: web.title, url: (web.url ?? start).absoluteString)
                        } label: { Image(systemName: "bookmark") }
                            .disabled(!model.canWrite).accessibilityLabel("Bookmark this page")
                        Spacer()
                        Button { UIApplication.shared.open(web.url ?? start) } label: { Image(systemName: "safari") }
                            .accessibilityLabel("Open in my browser")
                    }
                }
                .toolbarBackground(.visible, for: .bottomBar, .navigationBar)
        }
        .sheet(item: $draft) { NodeEditor(draft: $0) }
        .onAppear { web.load(start) }
    }
}

private struct WebViewHost: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// The web view and what the bars around it show of it.
@MainActor
final class WebState: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let view: WKWebView
    @Published var title = ""
    @Published var url: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loading = false
    @Published var progress = 0.0
    private var watching: [NSKeyValueObservation] = []
    private var started = false

    var host: String? {
        guard let h = url?.host else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .default()  // sign-ins stay between pages and between visits
        view = WKWebView(frame: .zero, configuration: config)
        super.init()
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = true
        view.navigationDelegate = self
        view.uiDelegate = self
        watching = [
            view.observe(\.title) { [weak self] v, _ in Task { @MainActor in self?.title = v.title ?? "" } },
            view.observe(\.url) { [weak self] v, _ in Task { @MainActor in self?.url = v.url } },
            view.observe(\.canGoBack) { [weak self] v, _ in Task { @MainActor in self?.canGoBack = v.canGoBack } },
            view.observe(\.canGoForward) { [weak self] v, _ in Task { @MainActor in self?.canGoForward = v.canGoForward } },
            view.observe(\.isLoading) { [weak self] v, _ in Task { @MainActor in self?.loading = v.isLoading } },
            view.observe(\.estimatedProgress) { [weak self] v, _ in Task { @MainActor in self?.progress = v.estimatedProgress } },
        ]
    }

    func load(_ url: URL) {
        guard !started else { return }
        started = true
        self.url = url
        view.load(URLRequest(url: url))
    }

    /// Links to other apps (mailto:, tel:, the App Store…) go to them; the web stays here.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        if ["http", "https", "about", "blob", "data", "file"].contains(scheme) { return .allow }
        _ = await UIApplication.shared.open(url)
        return .cancel
    }

    /// A link that wants a new window opens in this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }
}
