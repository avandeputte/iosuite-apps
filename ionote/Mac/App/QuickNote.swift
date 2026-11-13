import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The quick note shortcut (Settings › General, ⌃⌥N by default): from any app, a small window to type a note in,
/// saved with ⌘Return. A Carbon hot key, so it needs no Accessibility permission.
@MainActor
final class HotKey {
    static let shared = HotKey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var current = ""

    /// The choices in Settings: (stored value, what it shows).
    static let choices: [(String, String)] = [
        ("ctrlOptN", "⌃⌥N"), ("optCmdN", "⌥⌘N"), ("ctrlOptCmdN", "⌃⌥⌘N"), ("ctrlOptSpace", "⌃⌥Space"), ("off", "Off"),
    ]

    /// Registers the shortcut chosen in Settings (again, when it changed).
    func apply() {
        let choice = UserDefaults.standard.string(forKey: Prefs.quickNoteHotKey) ?? "ctrlOptN"
        guard choice != current else { return }
        current = choice
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        let combo: (key: Int, mods: Int)?
        switch choice {
        case "ctrlOptN": combo = (kVK_ANSI_N, controlKey | optionKey)
        case "optCmdN": combo = (kVK_ANSI_N, optionKey | cmdKey)
        case "ctrlOptCmdN": combo = (kVK_ANSI_N, controlKey | optionKey | cmdKey)
        case "ctrlOptSpace": combo = (kVK_Space, controlKey | optionKey)
        default: combo = nil
        }
        guard let combo else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x696F4E54), id: 1)  // 'ioNT'
        let status = RegisterEventHotKey(UInt32(combo.key), UInt32(combo.mods), id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            Log.app.error("quick note shortcut \(choice, privacy: .public) not registered: \(status)")
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { QuickNote.show() } }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// The quick note window: a floating panel over whatever app is in front.
@MainActor
enum QuickNote {
    private static var panel: NSPanel?

    static func show() {
        let panel = self.panel ?? make()
        self.panel = panel
        panel.contentViewController = NSHostingController(rootView: QuickNoteView { close() }.environmentObject(NotesStore.shared))
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    static func close() {
        panel?.orderOut(nil)
        // back to the app you were in, unless the main window is open
        if !(NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isVisible }) { NSApp.hide(nil) }
    }

    private static func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Quick Note"
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

private struct QuickNoteView: View {
    @EnvironmentObject private var store: NotesStore
    let done: () -> Void
    @State private var text = ""
    @State private var folderID: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write a note… The first line is its title.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .focused($focused)
            HStack {
                Picker("Folder", selection: $folderID) {
                    Text("No Folder").tag(String?.none)
                    ForEach(store.folders) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Cancel", role: .cancel, action: done)
                    .keyboardShortcut(.cancelAction)
                Button("Save Note", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 30)
        .frame(minWidth: 380, minHeight: 200)
        .onAppear { focused = true }
    }

    private func save() {
        guard let note = store.createTextNote(text, source: "manual") else { return }
        if let folderID { store.moveNote(id: note.id, toFolder: folderID) }
        text = ""
        done()
    }
}
