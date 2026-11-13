import SwiftUI
import UIKit

/// A page open in the built-in browser.
struct Page: Identifiable {
    let id = UUID()
    let url: URL
}

/// Where a tapped link opens.
enum OpenIn: String, CaseIterable, Identifiable {
    case app, browser
    var id: String { rawValue }
    var label: String { self == .app ? "In ioStart" : "In my browser" }
}

/// The signed-in account and the bookmark tree, kept the same as the start page's.
@MainActor
final class AppModel: ObservableObject {
    @Published var account: Account?
    @Published var tree: [Node] = []
    @Published var rev = 0
    @Published var canWrite = true
    @Published var loaded = false
    @Published var problem: String?
    @Published var browsing: Page?
    @Published var openIn: OpenIn {
        didSet { Shared.defaults.set(openIn.rawValue, forKey: "openIn") }
    }

    init() {
        openIn = OpenIn(rawValue: Shared.defaults.string(forKey: "openIn") ?? "") ?? .app
        account = Account.load()
        if account != nil, let kept = TreeCache.load() {
            tree = kept.tree
            rev = kept.rev
            loaded = true
        }
    }

    private var api: API? { account.map(API.init(account:)) }

    private func take(_ state: TreeState) {
        tree = state.tree
        rev = state.rev
        loaded = true
        TreeCache.save(state)
    }

    private func failed(_ error: Error, quiet: Bool = false) {
        if case APIError.signedOut = error {
            signOut()
            problem = error.localizedDescription
        } else if !quiet {
            problem = error.localizedDescription
        }
    }

    /// The tree as the start page has it now. Quiet: a failure (no network) leaves what is shown.
    func refresh(quiet: Bool = true) async {
        guard let api else { return }
        do {
            take(try await api.tree())
            if let me = try? await api.hello() { canWrite = me.canWrite }
        } catch {
            failed(error, quiet: quiet)
        }
    }

    /// Sends changes; the tree becomes the start page's answer. False when they did not go through.
    @discardableResult
    func send(_ ops: [Op]) async -> Bool {
        guard let api, !ops.isEmpty else { return false }
        do {
            let r = try await api.sync(base: rev, ops: ops)
            take(TreeState(rev: r.rev, tree: r.tree))
            return true
        } catch {
            failed(error)
            await refresh()  // back to what the start page has
            return false
        }
    }

    // MARK: changes

    func add(folder: Bool, title: String, url: String?, to parent: Int?) async -> Bool {
        await send([.create(parent: parent, folder: folder, title: title, url: url)])
    }

    func delete(_ node: Node) async {
        if let p = tree.parent(of: node.id) {
            tree.change(childrenOf: p) { $0.removeAll { $0.id == node.id } }  // at once; the answer confirms it
        }
        await send([.delete(node.id)])
    }

    /// Drag and drop inside one folder.
    func reorder(in parent: Int?, from: IndexSet, to: Int) async {
        var ids: [Int] = []
        tree.change(childrenOf: parent) {
            $0.move(fromOffsets: from, toOffset: to)
            ids = $0.map(\.id)
        }
        await send([.order(parent: parent, ids: ids)])
    }

    // MARK: opening

    func open(_ node: Node) {
        guard let url = node.link else { return }
        open(url)
    }

    func open(_ url: URL, in place: OpenIn? = nil) {
        let web = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        if (place ?? openIn) == .app && web {
            browsing = Page(url: url)
        } else {
            UIApplication.shared.open(url)
        }
    }

    // MARK: the account

    func signedIn(_ account: Account) async {
        account.save()
        self.account = account
        loaded = false
        await refresh(quiet: false)
    }

    func signOut() {
        Account.clear()
        account = nil
        tree = []
        rev = 0
        loaded = false
    }
}
