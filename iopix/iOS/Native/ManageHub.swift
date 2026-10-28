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
                link("Duplicate files", "doc.on.doc", Hue.orange) { ManageDuplicatesScreen() }
                link("Near-duplicates", "square.on.square", Hue.orange) { ManageNearDuplicatesScreen() }
                link("Bursts & best shots", "square.stack.3d.down.right", Hue.amber) { ManageBurstsScreen() }
                link("Detected content", "sparkles", Hue.purple) { ManageDetectedScreen() }
                link("Metadata quality", "checkmark.seal", Hue.teal) { ManageQualityScreen() }
                link("Date suggestions", "calendar.badge.clock", Hue.amber) { ManageDateSuggestScreen() }
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
