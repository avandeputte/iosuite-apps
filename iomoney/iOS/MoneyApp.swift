import SwiftUI

@main
struct MoneyApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                // nothing of the accounts in the app switcher's picture
                .overlay { if phase != .active || model.locked { LockCover() .environmentObject(model) } }
                .onChange(of: phase) { _, now in
                    switch now {
                    case .background: model.leftScreen()
                    case .active:
                        if model.locked { model.unlock() } else { Task { await model.refresh() } }
                    default: break
                    }
                }
        }
    }
}

/// What covers the accounts while the app is not in front, and until the person unlocks it.
struct LockCover: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                Image("Mark").resizable().frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                Text("ioMoney").font(.title2.bold())
                if model.locked {
                    Button("Unlock") { model.unlock() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.credential == nil {
                SignInView()
            } else {
                TabView {
                    OverviewView().tabItem { Label("Overview", systemImage: "chart.line.uptrend.xyaxis") }
                    TransactionsTab().tabItem { Label("Transactions", systemImage: "list.bullet") }
                        .badge(model.summary?.review ?? 0)
                    SpendingView().tabItem { Label("Spending", systemImage: "chart.pie") }
                    BillsView().tabItem { Label("Bills", systemImage: "calendar") }
                    PortfolioView().tabItem { Label("Investments", systemImage: "chart.bar.xaxis") }
                }
                .task(id: model.locked) { if !model.locked { await model.refresh() } }
            }
        }
        .sheet(isPresented: $model.showSettings) { SettingsView().environmentObject(model) }
        .alert("Something went wrong", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }
}

/// The sign-in of the ioSuite apps (shared/DeviceSignIn): the server's address for apps, the name and password,
/// and the code of two-step sign-in when the account has it. This device gets an app password of its own.
struct SignInView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            DeviceSignInForm(app: .iomoney) { answer in
                Task { await model.signedIn(answer.credential) }
            }
            .safeAreaInset(edge: .top) {
                HStack(spacing: 12) {
                    Image("Mark")
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading) {
                        Text("ioMoney").font(.title2.bold())
                        Text("The household's accounts, spending and bills.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Ask for Face ID or the passcode", isOn: $model.lockOn).disabled(!AppModel.canLock)
                } footer: {
                    Text(AppModel.canLock ? "Each time the app is opened. Nothing of your accounts is kept on this device, and nothing shows in the app switcher."
                         : "This device has no passcode, so the app cannot ask for it.")
                }
                if let c = model.credential {
                    Section {
                        LabeledContent("Server", value: c.address.replacingOccurrences(of: "https://", with: ""))
                        LabeledContent("Signed in as", value: c.name)
                        Button("Sign out", role: .destructive) { asking = true }
                    } header: {
                        Text("Account")
                    } footer: {
                        Text("This device signs in with a password of its own. Signing out gives it back; you can also remove it in Settings › Account on the web. You see the household's accounts and the private ones you own or were shown, as on the web.")
                    }
                }
                Section {
                    LabeledContent("Version", value: version)
                } footer: {
                    Text("Rules, transfers, Tidy up, reconciling and Monarch Money's settings are on the web.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Sign out of ioMoney?", isPresented: $asking, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    dismiss()
                    model.signOut()
                }
            }
        }
    }
}

/// An amount: green when it is money in, plain when it is money out.
struct Amount: View {
    let value: Double
    let currency: String?
    var body: some View {
        Text(Money.text(value, currency, sign: value > 0))
            .monospacedDigit()
            .foregroundStyle(value > 0 ? Color.green : Color.primary)
    }
}

/// How far back a chart looks.
enum Span: Int, CaseIterable, Identifiable {
    case month = 30, quarter = 90, year = 365, five = 1825
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .month: return "1M"
        case .quarter: return "3M"
        case .year: return "1Y"
        case .five: return "5Y"
        }
    }
}
