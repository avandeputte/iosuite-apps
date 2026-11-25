import SwiftUI

/// The person's feeds and how many articles are unread, kept the same as the start page's.
@MainActor
final class NewsModel: ObservableObject {
    @Published var overview = FeedsOverview()
    @Published var loaded = false
    @Published var problem: String?

    /// The feeds as the start page has them now. `look`: have it look for new articles first.
    func refresh(_ account: Account?, look: Bool = false) async {
        guard let account else { return }
        let api = API(account: account)
        do {
            if look { _ = try? await api.lookForNews() }
            overview = try await api.feeds()
            loaded = true
            problem = nil
        } catch {
            problem = NewsModel.told(error)
        }
    }

    /// An article was read or not (in a list or by opening it): the counts follow at once; the next refresh confirms.
    func count(_ article: Article, read: Bool) {
        let by = read ? -1 : 1
        overview.unread = max(0, overview.unread + by)
        if let i = overview.feeds.firstIndex(where: { $0.id == article.feedId }) {
            overview.feeds[i].unread = max(0, overview.feeds[i].unread + by)
        }
    }

    func forget() {
        overview = FeedsOverview()
        loaded = false
        problem = nil
    }

    /// An error of the reader's calls as it should be told: a start page from before the app's reader answers 404
    /// at the address for apps, and an account that only looks (a viewer) keeps no feeds.
    static func told(_ error: Error) -> String {
        if case APIError.server(404, _) = error { return "Your start page needs an update before ioStart can read your feeds." }
        if case APIError.readOnly = error { return "This account cannot keep feeds: on the start page it only looks." }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
