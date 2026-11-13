import SwiftUI
import UIKit
import WebKit

/// A page in the back or forward history, for the lists on the arrows.
struct HistoryItem: Identifiable {
    let id = UUID()
    let item: WKBackForwardListItem
    var title: String { (item.title?.isEmpty == false ? item.title : nil) ?? WebAddress.site(item.url) ?? item.url.absoluteString }
}

/// One browsing session: the web view and what the bars around it show of it. A private one keeps its cookies,
/// sign-ins and cache in memory only, apart from the usual session's, and they go when it is closed.
@MainActor
final class WebState: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let view: WKWebView
    let isPrivate: Bool
    @Published var title = ""
    @Published var url: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loading = false
    @Published var progress = 0.0
    @Published var secure = false
    /// Why the page did not load, shown in its place.
    @Published var failure: String?
    /// The address that did not open (WebKit's own address goes back to the page before it).
    @Published var failedURL: URL?
    /// A page was asked for; until then the browser shows its empty page and the address bar.
    @Published private(set) var started = false
    private var watching: [NSKeyValueObservation] = []

    var site: String? { WebAddress.site(url) }
    /// Nothing opened yet (or only the blank page): the address bar asks for an address.
    var isBlank: Bool { url == nil || url?.absoluteString == "about:blank" }

    init(isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // the usual session keeps sign-ins between pages and visits; a private one has a store of its own, in memory
        config.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        // sites look for these words to tell a full mobile browser from a web view inside an app
        config.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
        view = WKWebView(frame: .zero, configuration: config)
        super.init()
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = true
        view.isFindInteractionEnabled = true
        view.navigationDelegate = self
        view.uiDelegate = self
        let pull = UIRefreshControl()
        pull.addAction(UIAction { [weak self, weak pull] _ in
            self?.reload()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                pull?.endRefreshing()
            }
        }, for: .valueChanged)
        view.scrollView.refreshControl = pull
        watching = [
            view.observe(\.title) { [weak self] v, _ in Task { @MainActor in self?.title = v.title ?? "" } },
            view.observe(\.url) { [weak self] v, _ in Task { @MainActor in self?.url = v.url } },
            view.observe(\.canGoBack) { [weak self] v, _ in Task { @MainActor in self?.canGoBack = v.canGoBack } },
            view.observe(\.canGoForward) { [weak self] v, _ in Task { @MainActor in self?.canGoForward = v.canGoForward } },
            view.observe(\.isLoading) { [weak self] v, _ in Task { @MainActor in self?.loading = v.isLoading } },
            view.observe(\.estimatedProgress) { [weak self] v, _ in Task { @MainActor in self?.progress = v.estimatedProgress } },
            view.observe(\.hasOnlySecureContent) { [weak self] v, _ in Task { @MainActor in self?.secure = v.hasOnlySecureContent } },
        ]
    }

    func load(_ url: URL) {
        started = true
        failure = nil
        failedURL = nil
        self.url = url
        view.load(URLRequest(url: url))
    }

    func reload() {
        if let again = failedURL { load(again); return }
        failure = nil
        if view.url == nil, let url { view.load(URLRequest(url: url)) } else { view.reload() }
    }

    func back() { clearFailure(); view.goBack() }
    func forward() { clearFailure(); view.goForward() }
    func go(to item: HistoryItem) { clearFailure(); view.go(to: item.item) }
    private func clearFailure() { failure = nil; failedURL = nil }

    /// The pages behind (nearest first) or ahead, for the lists on the arrows.
    func history(back: Bool) -> [HistoryItem] {
        let list = back ? Array(view.backForwardList.backList.reversed()) : view.backForwardList.forwardList
        return list.prefix(15).map { HistoryItem(item: $0) }
    }

    func find() {
        view.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    // MARK: navigation

    /// Links to other apps (mailto:, tel:, the App Store…) go to them; the web stays here.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        if ["http", "https", "about", "blob", "data", "file"].contains(scheme) { return .allow }
        _ = await UIApplication.shared.open(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        clearFailure()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }  // stopped, or another page was asked for
        if e.domain == "WebKitErrorDomain" && [102, 204].contains(e.code) { return }  // handed to another app; a download or media
        failedURL = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? view.url ?? url
        failure = e.localizedDescription
    }

    /// The page's process was ended by the system (memory): load it again rather than show an empty page.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: windows and dialogs

    /// A link that wants a new window opens in this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    /// The view controller on top, to show a page's dialog over.
    private var presenter: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var top = scenes.flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    private func who(_ frame: WKFrameInfo) -> String {
        frame.request.url?.host ?? "This page"
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        guard let presenter else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let alert = UIAlertController(title: who(frame), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done.resume() })
            presenter.present(alert, animated: true)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard let presenter else { return false }
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: who(frame), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done.resume(returning: true) })
            presenter.present(alert, animated: true)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard let presenter else { return nil }
        return await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            let alert = UIAlertController(title: who(frame), message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done.resume(returning: nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in done.resume(returning: alert?.textFields?.first?.text ?? "") })
            presenter.present(alert, animated: true)
        }
    }
}

/// Forgets what the usual browsing session keeps: cookies and sign-ins, caches, the sites' own storage.
@MainActor
func clearBrowsingData() async {
    await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
}
