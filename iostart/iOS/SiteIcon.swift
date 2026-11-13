import SwiftUI
import UIKit

/// A link's icon: the site's own, as the start page keeps it, else two letters on a colour of the name's.
struct SiteIcon: View {
    @EnvironmentObject private var model: AppModel
    let node: Node
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit().padding(4)
            } else {
                Text(letters)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(hue: hue, saturation: 0.45, brightness: 0.62))
            }
        }
        .frame(width: 32, height: 32)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: node.url) {
            guard let account = model.account else { return }
            image = await IconStore.shared.icon(for: node, account: account)
        }
    }

    private var letters: String {
        let words = node.name.split { !$0.isLetter && !$0.isNumber }
        if words.count >= 2, let a = words[0].first, let b = words[1].first { return String([a, b]).uppercased() }
        return String(node.name.prefix(2)).capitalized
    }

    private var hue: Double {
        let sum = (node.host ?? node.name).unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        return Double(sum) / 360
    }
}

/// The icons already fetched, by site, in memory and on disk (they change rarely).
actor IconStore {
    static let shared = IconStore()

    private let memory = NSCache<NSString, UIImage>()
    private var missing: Set<String> = []
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func icon(for node: Node, account: Account) async -> UIImage? {
        guard let host = node.link?.host?.lowercased() else { return nil }
        if let hit = memory.object(forKey: host as NSString) { return hit }
        if missing.contains(host) { return nil }
        let file = dir.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_"))
        let fresh = ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > Date().addingTimeInterval(-7 * 86400)
        if fresh, let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory.setObject(img, forKey: host as NSString)
            return img
        }
        guard let url = API(account: account).iconURL(for: node.id) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(API.basic(account), forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await API.session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = UIImage(data: data) else {
            missing.insert(host)  // none (yet), or a kind of image the phone cannot draw: asked again at the next start
            return nil
        }
        try? data.write(to: file, options: .atomic)
        memory.setObject(img, forKey: host as NSString)
        return img
    }
}
