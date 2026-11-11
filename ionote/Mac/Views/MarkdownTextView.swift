import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Connects the formatting bar to the text view it formats.
@MainActor final class MarkdownFormatter {
    weak var textView: MarkdownNSTextView?
    func apply(_ cmd: MarkdownFormat.Command) { textView?.apply(cmd) }
}

/// The note's text, plain, with the formatting bar's commands and shortcuts (⌘B, ⌘I…) and lists that continue
/// on Return. Every change goes through insertText, so ⌘Z undoes it like typing.
final class MarkdownNSTextView: NSTextView {
    func apply(_ cmd: MarkdownFormat.Command) {
        perform(MarkdownFormat.edit(cmd, text: string, selection: selectedRange()))
        window?.makeFirstResponder(self)
    }

    func perform(_ ed: MarkdownFormat.Edit) {
        insertText(ed.text, replacementRange: ed.range)
        setSelectedRange(ed.selection)
        scrollRangeToVisible(ed.selection)
    }

    /// The keys by their place on the keyboard, the same as the web app (so ⇧⌘8 is the 8 key on any layout).
    private static let keyCodes: [String: Int] = ["b": kVK_ANSI_B, "i": kVK_ANSI_I, "x": kVK_ANSI_X, "e": kVK_ANSI_E,
                                                   "k": kVK_ANSI_K, "h": kVK_ANSI_H, "8": kVK_ANSI_8, "7": kVK_ANSI_7,
                                                   "l": kVK_ANSI_L, ".": kVK_ANSI_Period]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if window?.firstResponder === self, flags == .command || flags == [.command, .shift],
           let cmd = MarkdownFormat.Command.allCases.first(where: { c in
               guard let s = c.shortcut, let code = Self.keyCodes[s.key] else { return false }
               return Int(event.keyCode) == code && s.shift == flags.contains(.shift)
           }) {
            apply(cmd)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if !hasMarkedText(), let ed = MarkdownFormat.newline(text: string, selection: selectedRange()) {
            perform(ed)
            return
        }
        super.insertNewline(sender)
    }
}

/// A scrolling plain-text editor for a note's Markdown (TextEditor can't tell where the selection is).
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    let formatter: MarkdownFormatter

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let tv = MarkdownNSTextView(frame: .zero)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.smartInsertDeleteEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false  // Markdown wants straight quotes and plain dashes
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.string = text
        tv.delegate = context.coordinator
        scroll.documentView = tv
        formatter.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? MarkdownNSTextView else { return }
        formatter.textView = tv
        // a change from elsewhere (a box ticked in the formatted view, a sync): keep the caret where it can stay
        if tv.string != text, !tv.hasMarkedText() {
            let sel = tv.selectedRange()
            tv.string = text
            let n = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(sel.location, n), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        init(_ parent: MarkdownTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if parent.text != tv.string { parent.text = tv.string }
        }
    }
}

/// The formatting bar above the text: bold, italic, strikethrough, code, link | heading, lists, checklist, quote |
/// code block, divider. The same commands and shortcuts as the web app.
struct FormatBar: View {
    let action: (MarkdownFormat.Command) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(MarkdownFormat.Command.groups.enumerated()), id: \.offset) { i, group in
                if i > 0 { Divider().frame(height: 16).padding(.horizontal, 4) }
                ForEach(group) { cmd in
                    Button { action(cmd) } label: {
                        Image(systemName: cmd.systemImage)
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(cmd.help)
                    .accessibilityLabel(cmd.label)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }
}
