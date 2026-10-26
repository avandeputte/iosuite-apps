import SwiftUI

/// The library-management and review pages, as rows for the More list (one Section to drop in).
struct ManageMoreSection: View {
    @StateObject private var rights = ManageRights()

    var body: some View {
        Section("Library") {
            link("Import", "square.and.arrow.down.on.square", Hue.blue, editors: true) { ManageImportScreen() }
            link("Trash", "trash", Hue.rose, editors: true) { ManageTrashScreen() }
            link("Duplicate files", "doc.on.doc", Hue.orange) { ManageDuplicatesScreen() }
            link("Near-duplicates", "square.on.square", Hue.orange) { ManageNearDuplicatesScreen() }
            link("Bursts & best shots", "square.stack.3d.down.right", Hue.amber) { ManageBurstsScreen() }
            link("Detected content", "sparkles", Hue.purple) { ManageDetectedScreen() }
            link("Metadata quality", "checkmark.seal", Hue.teal, editors: true) { ManageQualityScreen() }
            link("Date suggestions", "calendar.badge.clock", Hue.amber, editors: true) { ManageDateSuggestScreen() }
            link("History", "clock.arrow.circlepath", Hue.slate) { ManageHistoryScreen() }
        }
        .task { await rights.load() }
    }

    @ViewBuilder private func link<D: View>(_ title: String, _ symbol: String, _ hue: Color, editors: Bool = false, @ViewBuilder _ dest: @escaping () -> D) -> some View {
        if !editors || rights.canWrite {
            NavigationLink { dest() } label: {
                Label { Text(title) } icon: {
                    Image(systemName: symbol).foregroundStyle(.white).font(.footnote)
                        .frame(width: 28, height: 28).background(hue, in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }
}
