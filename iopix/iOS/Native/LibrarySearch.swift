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
