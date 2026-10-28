import SwiftUI

extension View {
    /// The library search of Explore and Photos: people, tags and places suggested as you type, the text itself
    /// searched on Return. iPhone and iPad keep the system search bar under the title. On the Mac that bar lives in
    /// the window's toolbar, which loses it when another page has been shown in between, so the Mac gets a field
    /// of its own at the top of the page.
    func librarySearch(text: Binding<String>, query: Binding<PhotoQuery>, submit: @escaping () -> Void) -> some View {
        modifier(LibrarySearch(text: text, query: query, submit: submit))
    }
}

extension View {
    /// The library search on a page that is not Photos (Explore, People, Places): what it finds opens in Photos.
    /// `text`, when given, is the page's own filter too (People narrows its list as you type).
    func globalSearch(text: Binding<String>? = nil) -> some View {
        modifier(GlobalSearch(external: text))
    }
}

private struct GlobalSearch: ViewModifier {
    var external: Binding<String>?
    @EnvironmentObject private var router: Router
    @State private var own = ""
    @State private var query = PhotoQuery()

    func body(content: Content) -> some View {
        let text = external ?? $own
        content
            .librarySearch(text: text, query: $query) {
                let q = text.wrappedValue.trimmingCharacters(in: .whitespaces)
                if !q.isEmpty { show(PhotoQuery([("q", q)])) }
                text.wrappedValue = ""
            }
            .onChange(of: query) { _, q in
                guard !q.filters.isEmpty else { return }
                show(q)
                query = PhotoQuery()
                text.wrappedValue = ""
            }
            .task { await BulkCatalog.shared.load() }
    }

    private func show(_ q: PhotoQuery) {
        router.photosPath = [.photos(q)]
        router.tab = .photos
    }
}

private let searchPrompt = "Search people, tags, places, captions"

private struct LibrarySearch: ViewModifier {
    @Binding var text: String
    @Binding var query: PhotoQuery
    let submit: () -> Void

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.safeAreaInset(edge: .top, spacing: 0) {
            InlineSearchBar(text: $text, query: $query, submit: submit)
        }
        #else
        content
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: searchPrompt)
            .searchSuggestions { SearchSuggestionRows(text: $text, query: $query) }
            .onSubmit(of: .search, submit)
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// A search field in the page, with the suggestions in a panel under it.
private struct InlineSearchBar: View {
    @Binding var text: String
    @Binding var query: PhotoQuery
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(searchPrompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { submit(); focused = false }
                .onKeyPress(.escape) { text = ""; focused = false; return .handled }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .topLeading) {
            if focused, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        SearchSuggestionRows(text: $text, query: $query)
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.horizontal, 16)
                .offset(y: 52)
            }
        }
        .zIndex(1)
    }
}
#endif

/// The words of a toolbar button (Close, Cancel, Done): kept at their full width, so the glass capsule around them
/// on iPad and Mac grows to fit instead of cutting the word off.
struct BarText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).lineLimit(1).fixedSize() }
}

/// The button that closes a sheet without saving (Close, Cancel, Done on the left): an ✕, as iOS and macOS draw it
/// now, which fits the round glass button the system gives that spot on iPad and Mac. The word is what VoiceOver says.
struct CloseLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Image(systemName: "xmark").accessibilityLabel(text) }
}
