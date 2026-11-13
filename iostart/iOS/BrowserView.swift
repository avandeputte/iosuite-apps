import SwiftUI
import WebKit

/// The built-in browser: one page at a time, with an address bar (an address, or words to search for), back and
/// forward (press and hold either for the pages before or after), share, "bookmark this", private pages, and a way
/// out to the real browser.
struct BrowserView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let page: Page
    @StateObject private var web: WebState
    @State private var draft: Draft?
    @State private var editing = false
    @State private var typed = ""
    @FocusState private var addressFocused: Bool

    init(page: Page) {
        self.page = page
        _web = StateObject(wrappedValue: WebState(isPrivate: page.isPrivate))
    }

    private var here: URL? { (web.failure != nil ? web.failedURL : nil) ?? web.url ?? page.url }

    var body: some View {
        NavigationStack {
            content
                .overlay(alignment: .top) {
                    if web.loading {
                        ProgressView(value: web.progress).progressViewStyle(.linear).animation(.default, value: web.progress)
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { topBar; bottomBar }
                .toolbarBackground(.visible, for: .bottomBar, .navigationBar)
                .toolbarBackground(page.isPrivate ? Color(red: 0.16, green: 0.15, blue: 0.27) : Color(.systemBackground).opacity(0), for: .bottomBar, .navigationBar)
                .toolbarColorScheme(page.isPrivate ? .dark : nil, for: .bottomBar, .navigationBar)
        }
        .sheet(item: $draft) { NodeEditor(draft: $0) }
        .onDisappear {
            web.view.pauseAllMediaPlayback(completionHandler: nil)  // Done, or another page in its place: no more sound
        }
        .onAppear {
            guard !web.started, !editing else { return }  // again after a sheet closes: leave the page as it is
            if let url = page.url { web.load(url) } else { startTyping() }
        }
    }

    /// The page (or the empty page) with, over it, the suggestions while typing or why the page did not open. The
    /// page underneath stays the same view while typing: swapping it for the list rebuilt the bars and took the
    /// keyboard away after the first letter.
    private var content: some View {
        base.overlay {
            if editing && !typed.trimmingCharacters(in: .whitespaces).isEmpty && typed != here?.absoluteString {
                suggestions
            } else if let why = web.failure, !editing {
                failure(why)
            }
        }
    }

    @ViewBuilder private var base: some View {
        if web.started {
            WebViewHost(view: web.view).ignoresSafeArea(edges: .bottom)
        } else {
            VStack(spacing: 12) {
                Image(systemName: page.isPrivate ? "eye.slash" : "globe").font(.system(size: 44)).foregroundStyle(.secondary)
                Text(page.isPrivate ? "Private page" : "New page").font(.title3.weight(.semibold))
                Text(page.isPrivate
                     ? "Type an address or something to search for. Nothing of this page is kept: no history, cookies or sign-ins once you close it."
                     : "Type an address or something to search for.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(page.isPrivate ? Color(red: 0.11, green: 0.10, blue: 0.19) : Color(.systemBackground))
            .environment(\.colorScheme, page.isPrivate ? .dark : .light)
        }
    }

    @ToolbarContentBuilder private var topBar: some ToolbarContent {
        if editing {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search or type an address", text: $typed)
                        .keyboardType(.webSearch)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit(go)
                    if !typed.isEmpty {
                        Button { typed = ""; addressFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
                .frame(minWidth: 240)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") {
                    if web.started { editing = false } else { dismiss() }
                }
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .principal) {
                Button(action: startTyping) {
                    HStack(spacing: 4) {
                        if page.isPrivate {
                            Image(systemName: "eye.slash").font(.caption).foregroundStyle(.secondary)
                                .accessibilityLabel("Private page")
                        }
                        if here?.scheme == "https" { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                        VStack(spacing: 0) {
                            Text(web.failure != nil ? (WebAddress.site(here) ?? "") : web.title.isEmpty ? (web.site ?? "Search or type an address") : web.title)
                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                            if web.failure == nil, let host = web.site, !web.title.isEmpty {
                                Text(host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: 260)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Address")
                .accessibilityValue(here?.absoluteString ?? "")
                .accessibilityHint("Type an address or a search")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if web.loading { web.view.stopLoading() } else { web.reload() }
                } label: {
                    Image(systemName: web.loading ? "xmark" : "arrow.clockwise")
                }
                .disabled(!web.started)
                .accessibilityLabel(web.loading ? "Stop" : "Reload")
            }
        }
    }

    @ToolbarContentBuilder private var bottomBar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Menu {
                ForEach(web.history(back: true)) { item in Button(item.title) { web.go(to: item) } }
            } label: {
                Image(systemName: "chevron.backward")
            } primaryAction: {
                web.back()
            }
            .disabled(!web.canGoBack).accessibilityLabel("Back")
            Spacer()
            Menu {
                ForEach(web.history(back: false)) { item in Button(item.title) { web.go(to: item) } }
            } label: {
                Image(systemName: "chevron.forward")
            } primaryAction: {
                web.forward()
            }
            .disabled(!web.canGoForward).accessibilityLabel("Forward")
            Spacer()
            if let here {
                ShareLink(item: here) { Image(systemName: "square.and.arrow.up") }
            } else {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                if let here { draft = Draft(folder: false, parent: nil, title: web.title, url: here.absoluteString) }
            } label: { Image(systemName: "bookmark") }
                .disabled(!model.canWrite || here == nil).accessibilityLabel("Bookmark this page")
            Spacer()
            Menu {
                Button { model.newPage() } label: { Label("New page", systemImage: "plus.square.on.square") }
                Button { model.newPage(privately: true) } label: { Label("New private page", systemImage: "eye.slash") }
                if let here {
                    if page.isPrivate {
                        Button { model.open(here, in: .app) } label: { Label("Open as a normal page", systemImage: "eye") }
                    } else {
                        Button { model.open(here, privately: true) } label: { Label("Open in a private page", systemImage: "eye.slash") }
                    }
                    Divider()
                    if web.started && web.failure == nil {
                        Button { web.find() } label: { Label("Find on page", systemImage: "doc.text.magnifyingglass") }
                    }
                    Button { UIPasteboard.general.url = here } label: { Label("Copy address", systemImage: "doc.on.doc") }
                    Button { UIApplication.shared.open(here) } label: { Label("Open in my browser", systemImage: "safari") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    /// While typing: the bookmarks that match, then going to the address or searching for the words.
    private var suggestions: some View {
        let hits = Array(model.tree.search(typed).prefix(8))
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearch = model.destination(t) == model.searchWith.url(for: t)
        return List {
            if !hits.isEmpty {
                Section("Bookmarks") {
                    ForEach(hits, id: \.node.id) { hit in
                        Button {
                            if let url = hit.node.link { open(url) }
                        } label: {
                            HStack(spacing: 12) {
                                SiteIcon(node: hit.node)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.node.name).foregroundStyle(.primary).lineLimit(1)
                                    Text(hit.node.host ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                Button(action: go) {
                    Label(isSearch ? "Search \(model.searchWith.name) for “\(t)”" : "Go to \(t)",
                          systemImage: isSearch ? "magnifyingglass" : "globe")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.never)
        .environment(\.colorScheme, page.isPrivate ? .dark : colorScheme)
    }

    /// In place of a page that did not open: why, its address, and Try again.
    private func failure(_ why: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("This page did not open").font(.title3.weight(.semibold))
            Text(why).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let address = here?.absoluteString {
                Text(address).font(.footnote).foregroundStyle(.tertiary).lineLimit(2).multilineTextAlignment(.center)
            }
            Button("Try again") { web.reload() }.buttonStyle(.borderedProminent).padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private func startTyping() {
        typed = here?.absoluteString ?? ""
        editing = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            addressFocused = true
            // the whole address selected, as a browser does: typing replaces it
            try? await Task.sleep(nanoseconds: 150_000_000)
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
    }

    private func open(_ url: URL) {
        editing = false
        addressFocused = false
        web.load(url)
    }

    private func go() {
        guard let url = model.destination(typed) else { return }
        open(url)
    }
}

private struct WebViewHost: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
