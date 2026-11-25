import SwiftUI

/// An admin or maintenance screen: shown when the home address answers (HomeServer), "Available at home only"
/// otherwise, instead of failing call by call.
struct HomeOnly<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @ObservedObject private var home = HomeServer.shared

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Group {
            switch home.state {
            case .reachable:
                content()
            case .unknown:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notSet, .unreachable:
                HomeOnlyNotice(title: title)
            }
        }
        .task { await home.check() }
        .onChange(of: home.state) { _, s in if s == .unknown { Task { await home.check() } } }
    }
}

/// What an admin screen shows away from home, or without a home address.
struct HomeOnlyNotice: View {
    let title: String
    @ObservedObject private var home = HomeServer.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "house").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Available at home only").font(.title3.bold())
            Text(home.state == .notSet
                 ? "\(title) is an admin screen, which the address for apps does not serve. Add your home address in Settings › Server to use it on your home network."
                 : "\(title) is an admin screen. It works on your home network, at \(AppConfig.homeURL?.host ?? "the home address").")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if home.state == .unreachable {
                Button("Try again") { Task { await home.check(force: true) } }
            }
        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
    }
}

/// Settings › Server: the address for apps, the home address for admin screens, signing out.
struct ServerSection: View {
    @EnvironmentObject private var queue: UploadQueue
    @ObservedObject private var home = HomeServer.shared
    @State private var homeText = AppConfig.homeURL?.absoluteString ?? ""
    var signedOut: () -> Void = {}

    var body: some View {
        Section {
            LabeledContent("Address", value: IopixClient.shared.server.absoluteString)
            if let name = IopixClient.shared.credential?.name {
                LabeledContent("Signed in as", value: name)
            }
            TextField("Home address", text: $homeText, prompt: Text("http://192.168.1.10:8080/pix"))
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .onSubmit(saveHome)
            if AppConfig.homeURL != nil {
                LabeledContent("Home address") {
                    switch home.state {
                    case .reachable: Text("Answers").foregroundStyle(.green)
                    case .unreachable: Text("Not reachable from here").foregroundStyle(.orange)
                    default: ProgressView()
                    }
                }
            }
            Button("Sign Out", role: .destructive) {
                Task {
                    await IopixClient.shared.signOut()
                    ImageCache.shared.removeAll()
                    await queue.refreshAccount()
                    signedOut()
                }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("\(HomeServer.hint): the address of ioPix's pages on your home network. The admin and maintenance screens use it, with this device's password; everything else uses the address for apps.")
        }
        .task { await home.check() }
        .onDisappear(perform: saveHome)
    }

    private func saveHome() {
        let typed = homeText
        Task { @MainActor in
            await HomeServer.setAddress(typed)
            homeText = AppConfig.homeURL?.absoluteString ?? ""
        }
    }
}
