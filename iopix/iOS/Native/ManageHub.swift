import SwiftUI

/// The library-management and review pages, as rows for the More list (one Section to drop in).
struct ManageMoreSection: View {
    @StateObject private var rights = ManageRights()

    var body: some View {
        // looking after the library: admins only, apart from what everyone browses
        if rights.isAdmin {
            Section("Library management") {
                link("Import", "square.and.arrow.down.on.square", Hue.blue) { ManageImportScreen() }
                link("Trash", "trash", Hue.rose) { ManageTrashScreen() }
                link("Near-duplicates", "square.on.square", Hue.orange) { ManageNearDuplicatesScreen() }
                link("Detected content", "sparkles", Hue.purple) { ManageDetectedScreen() }
                link("History", "clock.arrow.circlepath", Hue.slate) { ManageHistoryScreen() }
            }
        }
        Section {}.task { await rights.load() }
    }

    @ViewBuilder private func link<D: View>(_ title: String, _ symbol: String, _ hue: Color, @ViewBuilder _ dest: @escaping () -> D) -> some View {
        do {
            NavigationLink { dest() } label: {
                Label { Text(title) } icon: {
                    Image(systemName: symbol).foregroundStyle(.white).font(.footnote)
                        .frame(width: 28, height: 28).background(hue, in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }
}
