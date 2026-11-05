import SwiftUI

/// The dashed frame shown while photos are dragged over the window (Mac) or the page (iPad).
struct DropHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
            .background(Color.accentColor.opacity(0.08))
            .overlay(Text("Drop to send to ioPix").font(.title2.weight(.semibold)))
            .padding(8)
            .allowsHitTesting(false)
    }
}

extension Notification.Name {
    /// Load the iopix page again (⌘R, the Mac toolbar button, the iPad menu).
    static let iopixReload = Notification.Name("iopixReload")
    /// Open the Send photos sheet (⇧⌘U on an iPad keyboard).
    static let iopixSendPhotos = Notification.Name("iopixSendPhotos")
}
