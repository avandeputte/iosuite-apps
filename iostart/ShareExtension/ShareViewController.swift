import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "ioStart" in the share sheet of a browser (or any app that shares a link): the page's name and address, the
/// folder it goes in, Save. It talks to the start page itself, with the sign-in the app keeps for both.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable { case reading, editing, saving, saved, failed(String) }

    @Published var title = ""
    @Published var url = ""
    @Published var parent: Int?
    @Published var tree: [Node] = []
    @Published var phase: Phase = .reading

    let account = Account.load()
    private var rev = 0
    private weak var context: NSExtensionContext?

    init(context: NSExtensionContext?) {
        self.context = context
        if let kept = TreeCache.load() {
            tree = kept.tree
            rev = kept.rev
        }
        let last = Shared.defaults.integer(forKey: "lastFolder")
        parent = last != 0 && tree.node(last)?.folder == true ? last : nil
    }

    /// What was shared: a link (browsers), or text with a link in it; and the page's name when the app gave one.
    func read() async {
        let items = (context?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
        var name = ""
        var found: URL?
        for item in items {
            let text = item.attributedContentText?.string ?? item.attributedTitle?.string ?? ""
            if name.isEmpty { name = text }
            for provider in item.attachments ?? [] where found == nil {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let got = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
                    found = got as? URL ?? (got as? String).flatMap { URL(string: $0) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let got = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier), let s = got as? String {
                    found = ShareModel.link(in: s)
                    if name.isEmpty, found != nil { name = s }
                }
            }
        }
        if found == nil { found = ShareModel.link(in: name) }
        if let found, found.isFileURL == false {
            url = found.absoluteString
            // the text beside a link is often the link again, or a sentence around it: then the site's name will do
            let plain = name.trimmingCharacters(in: .whitespacesAndNewlines)
            title = plain.isEmpty || plain.contains("://") || plain.count > 200 ? (found.host ?? "") : plain
        }
        phase = .editing
        if let account, let fresh = try? await API(account: account).tree() {  // folders made since the app was last open
            tree = fresh.tree
            rev = fresh.rev
            TreeCache.save(fresh)
            if let p = parent, tree.node(p)?.folder != true { parent = nil }
        }
    }

    private static func link(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, options: [], range: range)?.url
    }

    func save() async {
        guard let account else { return }
        let address = tidyAddress(url)
        guard !address.isEmpty else { return }
        phase = .saving
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let r = try await API(account: account).sync(base: rev, ops: [
                .create(parent: parent, folder: false, title: name.isEmpty ? (URL(string: address)?.host ?? "") : name, url: address),
            ])
            TreeCache.save(TreeState(rev: r.rev, tree: r.tree))
            Shared.defaults.set(parent ?? 0, forKey: "lastFolder")
            phase = .saved
            try? await Task.sleep(nanoseconds: 700_000_000)
            close()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func close() {
        context?.completeRequest(returningItems: nil)
    }

    func cancel() {
        context?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            Group {
                if model.account == nil {
                    ContentUnavailableView("Sign in first", systemImage: "person.crop.circle.badge.exclamationmark",
                                           description: Text("Open ioStart and sign in to your start page, then share the page again."))
                } else if model.phase == .reading {
                    ProgressView()
                } else if model.phase == .saved {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                        Text("Saved to \(folderName(model.parent, in: model.tree))").font(.headline)
                    }
                } else {
                    form
                }
            }
            .navigationTitle("ioStart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.phase == .saving {
                        ProgressView()
                    } else if model.account != nil, model.phase != .saved, model.phase != .reading {
                        Button("Save") { Task { await model.save() } }
                            .disabled(model.url.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .task { await model.read() }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $model.title)
                TextField("Address", text: $model.url, axis: .vertical)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                NavigationLink {
                    FolderPicker(tree: model.tree, selection: $model.parent)
                } label: {
                    LabeledContent("Folder", value: folderName(model.parent, in: model.tree))
                }
            }
            if case .failed(let why) = model.phase {
                Section {
                    Text(why).foregroundStyle(.red).font(.callout)
                }
            }
        }
    }
}
