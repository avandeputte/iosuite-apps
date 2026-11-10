import SwiftUI

/// ionotes on iPhone and iPad: the same notes, folders and tags as the Mac, synced through your ionotes server.
/// The clipboard Inbox stays on the Mac; here you paste or pick photos straight into notes.
@main
struct IonotesApp: App {
    @StateObject private var store = NotesStore.shared
    @AppStorage(Prefs.appearance) private var appearance = "system"
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(Brand.teal)
                .preferredColorScheme(colorScheme)
        }
        .onChange(of: scenePhase) { _, phase in
            // Pick up notes changed elsewhere while ionotes was in the background; sync every minute while in use.
            store.setActive(phase == .active)
            // what was shared to ioNotes from other apps while it was away
            if phase == .active { Task { await store.importShares() } }
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
