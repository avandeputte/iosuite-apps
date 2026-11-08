import SwiftUI

/// The ioThing suite's other apps (iothing-auth's suite_apps, GET /api/auth/suite), as the web app shows them: when
/// other apps are registered, the ioPix mark top left opens a menu of them, each a link to that app. Alone, nothing
/// shows. Signed-in accounts only (the list needs one); a failure means no menu rather than an error.
@MainActor final class SuiteApps: ObservableObject {
    static let shared = SuiteApps()

    struct App: Identifiable {
        let id: String      // the app's key (iocontacts, ionotes…)
        let name: String
        let url: URL
        let icon: URL?
        let color: Color?
        let description: String?
        /// The letter of the fallback tile: "C" for ioContacts.
        var letter: String { String(name.replacingOccurrences(of: #"^io(?=[A-Z])"#, with: "", options: .regularExpression).prefix(1)).uppercased() }
    }

    @Published private(set) var apps: [App] = []
    private var loadedFor: String?  // the account the list was loaded for: loaded again when it changes

    func load(account: String?) async {
        guard account != loadedFor else { return }
        loadedFor = account
        guard let account, !account.isEmpty else { apps = []; return }
        guard let r = try? await IopixClient.shared.json("api/auth/suite", query: []) else { return }
        guard loadedFor == account else { return }  // the account changed meanwhile
        let me = r["app"] as? String
        apps = (r["items"] as? [[String: Any]] ?? []).compactMap { a in
            guard let key = a["app"] as? String, key != me, let url = (a["url"] as? String).flatMap({ URL(string: $0) }) else { return nil }
            return App(id: key, name: (a["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key, url: url,
                       icon: (a["icon"] as? String).flatMap { URL(string: $0, relativeTo: url)?.absoluteURL },
                       color: (a["color"] as? String).flatMap(Color.init(hex:)), description: a["description"] as? String)
        }
    }
}

/// The ioPix mark as a toolbar button: a grid of the other apps, each opening that app. Nothing when ioPix is alone.
struct SuiteMenuButton: View {
    @ObservedObject private var suite = SuiteApps.shared
    @Environment(\.openURL) private var openURL
    @State private var open = false

    var body: some View {
        if !suite.apps.isEmpty {
            Button { open.toggle() } label: {
                Image("Mark").resizable().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .accessibilityLabel("Open another ioThing app")
            .popover(isPresented: $open, arrowEdge: .top) {
                SuiteGrid(apps: suite.apps) { open = false; openURL($0) }
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}

private struct SuiteGrid: View {
    let apps: [SuiteApps.App]
    let open: (URL) -> Void

    var body: some View {
        let cols = min(3, apps.count)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 8), count: cols), spacing: 10) {
            ForEach(apps) { a in
                Button { open(a.url) } label: {
                    VStack(spacing: 6) {
                        icon(a)
                        Text(a.name).font(.caption).foregroundStyle(.primary).lineLimit(1)
                    }
                    .frame(width: 84)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(a.description ?? a.name)
            }
        }
        .padding(14)
    }

    @ViewBuilder private func icon(_ a: SuiteApps.App) -> some View {
        let fallback = ZStack {
            RoundedRectangle(cornerRadius: 12).fill(a.color ?? Brand.indigo)
            Text(a.letter).font(.title2.bold()).foregroundStyle(.white)
        }
        Group {
            if let icon = a.icon {
                AsyncImage(url: icon) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { fallback }
                }
            } else {
                fallback
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

extension Color {
    /// "#3b4a8c" or "#fff" (the suite's app colours); nil for anything else.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let shift: UInt64 = s.count == 8 ? 8 : 0
        self.init(red: Double((v >> (16 + shift)) & 0xff) / 255, green: Double((v >> (8 + shift)) & 0xff) / 255, blue: Double((v >> shift) & 0xff) / 255)
    }
}
