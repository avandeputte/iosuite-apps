import SwiftUI
import UIKit

/// Text that can be selected and copied the usual way: dragged across with the mouse or trackpad on the Mac and
/// iPad, or held on a touch screen. SwiftUI's own text selection only offers Copy for the whole text from a menu.
struct SelectableText: UIViewRepresentable {
    let text: String
    var style: UIFont.TextStyle = .body
    var bold = false
    var italic = false
    var secondary = false

    init(_ text: String, style: UIFont.TextStyle = .body, bold: Bool = false, italic: Bool = false, secondary: Bool = false) {
        self.text = text; self.style = style; self.bold = bold; self.italic = italic; self.secondary = secondary
    }

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.adjustsFontForContentSizeCategory = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        var font = UIFont.preferredFont(forTextStyle: style)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let d = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: d, size: 0) }
        if v.text != text { v.text = text }
        v.font = font
        v.textColor = secondary ? .secondaryLabel : .label
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 10_000
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(width, ceil(fit.width)), height: ceil(fit.height))
    }
}

extension View {
    /// On the Mac every piece of text in the app can be copied (right-click › Copy); the longer texts (the info pane,
    /// All metadata, the edit log) are `SelectableText`, which can be dragged across too. Buttons and menus keep
    /// acting on a click. iPhone and iPad keep text out of the way of taps and long-presses.
    @ViewBuilder func macTextSelection() -> some View {
        #if targetEnvironment(macCatalyst)
        textSelection(.enabled)
        #else
        self
        #endif
    }
}
