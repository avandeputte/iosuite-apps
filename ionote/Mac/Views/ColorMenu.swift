import SwiftUI

/// "Color ▸ None / Red / Orange …" for folders and tags in the sidebar.
struct ColorMenu: View {
    let selected: LabelColor?
    let pick: (LabelColor?) -> Void

    var body: some View {
        Menu("Color") {
            Button {
                pick(nil)
            } label: {
                if selected == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
            }
            Divider()
            ForEach(LabelColor.allCases) { color in
                Button {
                    pick(color)
                } label: {
                    // Menus draw symbols as templates (no colour), so use a drawn swatch.
                    Label { Text(color == selected ? "\(color.title) ✓" : color.title) } icon: { Image(nsImage: color.swatch) }
                }
            }
        }
    }
}

extension LabelColor {
    /// A small filled circle in this colour that keeps its colour inside menus.
    var swatch: NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
