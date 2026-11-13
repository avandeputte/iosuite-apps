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
                    if now == .active { Task { await model.refresh() } }  // also picks up what the share sheet added
                }
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
        .fullScreenCover(item: $model.browsing) { page in
            BrowserView(start: page.url).environmentObject(model)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }
}
