import SwiftUI

@main
struct BookmarksApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onChange(of: phase) { _, now in
                    if now == .active {
                        model.openPending()
                        Task { await model.refresh() }  // also picks up what the share sheet added; reloads the widgets
                    }
                }
                .onOpenURL { model.handle($0) }  // a widget's bookmark, event or task
                .onReceive(NotificationCenter.default.publisher(for: .ioStartOpenLink)) { _ in model.openPending() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.account == nil {
                SignInView()
            } else {
                NavigationStack {
                    FolderView(folderID: nil)
                        .navigationDestination(for: Int.self) { FolderView(folderID: $0) }
                }
            }
        }
        .sheet(isPresented: $model.showSettings) { SettingsView().environmentObject(model) }
        .fullScreenCover(item: $model.browsing) { page in
            BrowserView(page: page).environmentObject(model)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }
}
