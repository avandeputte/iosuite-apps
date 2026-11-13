import SwiftUI

/// Settings › Inbox Rules: what happens to a new copy or screenshot before it reaches the Inbox.
struct InboxRulesView: View {
    @EnvironmentObject private var store: NotesStore
    @State private var rules = InboxRules.all
    @State private var editing: InboxRule?

    var body: some View {
        Form {
            Section {
                if rules.isEmpty {
                    Text("No rules yet. Everything you copy goes into the Inbox.")
                        .foregroundStyle(.secondary)
                }
                ForEach($rules) { $rule in
                    HStack {
                        Toggle("", isOn: $rule.enabled).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.summary)
                            Text(outcome(rule)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing = rule }
                        Button(role: .destructive) {
                            rules.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete this rule")
                    }
                }
                .onMove { rules.move(fromOffsets: $0, toOffset: $1) }
                Button("Add Rule…") { editing = InboxRule() }
            } header: {
                Text("Inbox rules")
            } footer: {
                Text("The first rule that fits a new copy or screenshot decides: save it as a note right away (in a folder, with tags), or leave it out of the Inbox. Anything no rule fits goes into the Inbox as usual. Tip: right-click an Inbox item › Always Save Copies From… makes a rule for its app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: rules) { _, new in InboxRules.all = new }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let saved = InboxRules.all
            if saved != rules { rules = saved }
        }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { saved in
                if let i = rules.firstIndex(where: { $0.id == saved.id }) { rules[i] = saved } else { rules.append(saved) }
            }
            .environmentObject(store)
        }
    }

    private func outcome(_ rule: InboxRule) -> String {
        guard rule.action == .saveAsNote else { return "Left out of the Inbox" }
        var parts = ["Saved as a note"]
        if let name = store.folderName(rule.folderID) { parts.append("in \(name)") }
        if !rule.tagList.isEmpty { parts.append(rule.tagList.map { "#" + $0 }.joined(separator: " ")) }
        return parts.joined(separator: " ")
    }
}

private struct RuleEditor: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    @State var rule: InboxRule
    let save: (InboxRule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("When") {
                    Picker("What", selection: $rule.kind) {
                        ForEach(InboxRule.Kind.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Copied in an app named", text: $rule.app, prompt: Text("Any app, e.g. Safari"))
                    TextField("Text contains", text: $rule.contains, prompt: Text("Any text"))
                        .disabled(rule.kind == .image || rule.kind == .screenshot)
                }
                Section("Then") {
                    Picker("Action", selection: $rule.action) {
                        ForEach(InboxRule.Action.allCases) { Text($0.label).tag($0) }
                    }
                    if rule.action == .saveAsNote {
                        Picker("Folder", selection: $rule.folderID) {
                            Text("No Folder").tag(String?.none)
                            ForEach(store.folders) { Text($0.name).tag(Optional($0.id)) }
                        }
                        TextField("Tags", text: $rule.tags, prompt: Text("e.g. work, links"))
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 440, height: 420)
    }
}
