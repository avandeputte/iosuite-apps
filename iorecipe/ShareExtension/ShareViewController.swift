import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "ioRecipe" in the share sheet of a browser: the server fetches the page shared and keeps the recipe on it. It talks
/// to the server itself, with the sign-in the app keeps for both.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: ShareModel(context: extensionContext)))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable { case reading, importing, saved(String), failed(String) }

    @Published var phase = Phase.reading
    @Published var address = ""

    private weak var context: NSExtensionContext?

    init(context: NSExtensionContext?) { self.context = context }

    /// The link that was shared, sent to the server at once: there is nothing to ask.
    func run() async {
        guard let credential = Account.load() else {
            phase = .failed("Open ioRecipe and sign in first.")
            return
        }
        guard let url = await link() else {
            phase = .failed("Nothing with a web address was shared.")
            return
        }
        address = url.host ?? url.absoluteString
        phase = .importing
        do {
            let r = try await API(credential: credential).importPage(url.absoluteString)
            phase = .saved(r.title)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func link() async -> URL? {
        for item in (context?.inputItems ?? []).compactMap({ $0 as? NSExtensionItem }) {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let got = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
                   let url = got as? URL ?? (got as? String).flatMap({ URL(string: $0) }), url.scheme?.hasPrefix("http") == true {
                    return url
                }
            }
        }
        return nil
    }

    func close() { context?.completeRequest(returningItems: nil) }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                switch model.phase {
                case .reading:
                    ProgressView()
                case .importing:
                    ProgressView()
                    Text("Importing the recipe from \(model.address)…").multilineTextAlignment(.center)
                    Text("Some pages take a minute.").font(.footnote).foregroundStyle(.secondary)
                case .saved(let title):
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                    Text("“\(title)” is in ioRecipe.").multilineTextAlignment(.center)
                case .failed(let why):
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.orange)
                    Text(why).multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("ioRecipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { model.close() } }
            }
        }
        .task { await model.run() }
    }
}
