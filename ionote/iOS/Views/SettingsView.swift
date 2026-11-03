import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.appearance) private var appearance = "system"

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    SyncStatusView()
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("Notes, folders, tags and colours sync with ionotes on your Mac through your iCloud account. The clipboard Inbox stays on the Mac.")
                }

                Section {
                    Label("Paste: the clipboard button at the bottom of the notes list", systemImage: "doc.on.clipboard")
                    Label("Photos and screenshots: the photo button; their text is read so you can search for it", systemImage: "photo.badge.plus")
                } header: {
                    Text("Adding notes")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
