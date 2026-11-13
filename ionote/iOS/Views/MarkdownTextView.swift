import SwiftUI
import UIKit

/// The note's text, plain, growing with what's in it, with a formatting bar above the keyboard (bold, italic,
/// lists, checklist…), the web app's shortcuts on a hardware keyboard (⌘B, ⌘I…), and lists that continue on Return.
/// Every change goes through the text input system, so undo (shake, three-finger swipe, ⌘Z) takes it back.
struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MarkdownUITextView {
        let tv = MarkdownUITextView()
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.font = .preferredFont(forTextStyle: .body)
        tv.adjustsFontForContentSizeCategory = true
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.smartQuotesType = .no  // Markdown wants straight quotes and plain dashes
        tv.smartDashesType = .no
        tv.text = text
        tv.delegate = context.coordinator
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.inputAccessoryView = FormatAccessory(textView: tv)
        return tv
    }

    func updateUIView(_ tv: MarkdownUITextView, context: Context) {
        context.coordinator.parent = self
        // a change from elsewhere (a box ticked in the formatted view, a sync): keep the caret where it can stay
        if tv.text != text, tv.markedTextRange == nil {
            let sel = tv.selectedRange
            tv.text = text
            tv.selectedRange = NSRange(location: min(sel.location, (text as NSString).length), length: 0)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarkdownUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: max(height, 120))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextView
        init(_ parent: MarkdownTextView) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            if parent.text != tv.text { parent.text = tv.text }
        }

        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", tv.markedTextRange == nil, let tv = tv as? MarkdownUITextView,
                  let ed = MarkdownFormat.newline(text: tv.text, selection: range) else { return true }
            tv.perform(ed)
            return false
        }
    }
}

final class MarkdownUITextView: UITextView {
    func apply(_ cmd: MarkdownFormat.Command) {
        perform(MarkdownFormat.edit(cmd, text: text, selection: selectedRange))
    }

    func perform(_ ed: MarkdownFormat.Edit) {
        guard let a = position(from: beginningOfDocument, offset: ed.range.location),
              let b = position(from: a, offset: ed.range.length),
              let r = textRange(from: a, to: b) else { return }
        replace(r, withText: ed.text)
        selectedRange = ed.selection
        delegate?.textViewDidChange?(self)
        scrollRangeToVisible(ed.selection)
    }

    override var keyCommands: [UIKeyCommand]? {
        let mine = MarkdownFormat.Command.allCases.compactMap { cmd -> UIKeyCommand? in
            guard let s = cmd.shortcut else { return nil }
            let k = UIKeyCommand(title: cmd.label, action: #selector(formatKey(_:)), input: s.key,
                                 modifierFlags: s.shift ? [.command, .shift] : .command, propertyList: cmd.rawValue)
            k.wantsPriorityOverSystemBehavior = true
            return k
        }
        return (super.keyCommands ?? []) + mine
    }

    @objc private func formatKey(_ sender: UIKeyCommand) {
        if let raw = sender.propertyList as? String, let cmd = MarkdownFormat.Command(rawValue: raw) { apply(cmd) }
    }
}

/// The formatting bar above the keyboard: the same commands as the Mac and the web app, scrolling sideways when the
/// screen is narrow, and a button to put the keyboard away.
final class FormatAccessory: UIInputView {
    private weak var textView: MarkdownUITextView?

    init(textView: MarkdownUITextView) {
        self.textView = textView
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = false
        autoresizingMask = [.flexibleWidth]

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 2
        for (i, group) in MarkdownFormat.Command.groups.enumerated() {
            if i > 0 {
                let line = UIView()
                line.backgroundColor = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                line.widthAnchor.constraint(equalToConstant: 1).isActive = true
                line.heightAnchor.constraint(equalToConstant: 20).isActive = true
                stack.addArrangedSubview(spacer(6))
                stack.addArrangedSubview(line)
                stack.addArrangedSubview(spacer(6))
            }
            for cmd in group {
                stack.addArrangedSubview(button(cmd.systemImage, cmd.label) { [weak self] in self?.textView?.apply(cmd) })
            }
        }
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let done = button("keyboard.chevron.compact.down", "Hide Keyboard") { [weak self] in self?.textView?.resignFirstResponder() }
        done.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(done)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -4),
            done.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            done.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func spacer(_ w: CGFloat) -> UIView {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: w).isActive = true
        return v
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .body))
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        let b = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        b.accessibilityLabel = label
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return b
    }
}
