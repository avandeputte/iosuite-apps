import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@main
struct IopixApp: App {
    @StateObject private var queue = UploadQueue.shared
    @StateObject private var watcher = PhotosWatcher.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(queue)
                .environmentObject(watcher)
        }
        .onChange(of: phase) { _, now in
            guard now == .active else { return }
            watcher.checkNow()
            Task { await queue.refreshAccount() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var queue: UploadQueue
    @State private var showUploads = false
    @State private var server = AppConfig.serverURL

    var body: some View {
        IopixWebView(url: server) { Task { await queue.refreshAccount() } }
            .id(server)
            .background(Color(.systemBackground))
            .overlay(alignment: .bottomTrailing) {
                // hidden while the page asks for a sign-in: its sign-in sheet sits right where the button goes
                // (still shown when iopix can't be reached, so the server address can be changed)
                if queue.canSend || !queue.pending.isEmpty || !queue.reviewing.isEmpty || queue.offline {
                Button { showUploads = true } label: {
                    Image(systemName: !queue.pending.isEmpty ? "arrow.up.circle" : !queue.reviewing.isEmpty ? "photo.badge.plus" : "square.and.arrow.up")
                        .font(.title3.weight(.semibold))
                        .frame(width: 48, height: 48)
                        .background(.regularMaterial, in: Circle())
                        .overlay(alignment: .topTrailing) {
                            if !queue.pending.isEmpty || !queue.reviewing.isEmpty {
                                Text("\(queue.pending.count + queue.reviewing.count)")
                                    .font(.caption2.bold())
                                    .padding(4)
                                    .background(Color.accentColor, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .accessibilityLabel("Send photos to iopix")
                .padding(.trailing, 16)
                .padding(.bottom, 72)
                }
            }
            .sheet(isPresented: $showUploads, onDismiss: { server = AppConfig.serverURL }) {
                UploadsView()
            }
    }
}

/// A photo or video picked from the library, as its original file.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try PickedFile(copying: $0.file) }
        FileRepresentation(importedContentType: .image) { try PickedFile(copying: $0.file) }
    }

    init(copying file: URL) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: url)
    }
}

struct UploadsView: View {
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var watcher: PhotosWatcher
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [PhotosPickerItem] = []
    @State private var loading = false
    @State private var serverText = AppConfig.serverURL.absoluteString
    @State private var tokenID = ServiceToken.clientID ?? ""
    @State private var tokenSecret = ServiceToken.clientSecret ?? ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    accountRow
                    PhotosPicker(selection: $picked, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                        Label(loading ? "Getting your photos…" : "Choose photos and videos", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(loading)
                }

                Section {
                    Toggle("Look for new photos", isOn: Binding(get: { watcher.enabled }, set: { on in Task { await watcher.setEnabled(on) } }))
                    if !queue.reviewing.isEmpty {
                        NavigationLink {
                            ReviewView()
                        } label: {
                            Label("\(queue.reviewing.count) new photo\(queue.reviewing.count == 1 ? "" : "s") to look at", systemImage: "photo.badge.plus")
                        }
                    }
                    if watcher.enabled {
                        Button("Also list the last 7 days") { watcher.sendRecent(days: 7) }
                    }
                } footer: {
                    Text(watcher.note ?? "Photos and videos you take from now on are listed here when you open iopix, and you pick which ones to send. Photos already in iopix are skipped.")
                }

                if !queue.pending.isEmpty {
                    Section("Sending") {
                        ForEach(queue.pending) { ItemRow(item: $0) }
                    }
                }
                if !queue.finished.isEmpty {
                    Section {
                        ForEach(queue.finished.prefix(50)) { ItemRow(item: $0) }
                    } header: {
                        Text("Done")
                    } footer: {
                        HStack {
                            if queue.finished.contains(where: { $0.state == .failed }) {
                                Button("Try again") { queue.retryFailed() }
                            }
                            Spacer()
                            Button("Clear list") { queue.clearFinished() }
                        }
                    }
                }

                DestinationSection()

                Section {
                    TextField("Server address", text: $serverText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .onSubmit(saveServer)
                    DisclosureGroup("Cloudflare service token") {
                        TextField("Client ID", text: $tokenID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Client secret", text: $tokenSecret)
                        Button("Save token") {
                            ServiceToken.clientID = tokenID.trimmingCharacters(in: .whitespaces)
                            ServiceToken.clientSecret = tokenSecret.trimmingCharacters(in: .whitespaces)
                            Task { await queue.refreshAccount() }
                        }
                    }
                    if queue.account?.signedIn == true {
                        Button("Sign out", role: .destructive) {
                            Task {
                                await IopixClient.shared.signOut()
                                await CookieSync.clearWebView()
                                await queue.refreshAccount()
                            }
                        }
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Optional. With a service token, uploads get through Cloudflare even when its sign-in has run out.")
                }
            }
            .navigationTitle("Send to iopix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { saveServer(); dismiss() } }
            }
            .onChange(of: picked) { _, items in load(items) }
            .task { await queue.refreshAccount() }
        }
    }

    @ViewBuilder private var accountRow: some View {
        if let a = queue.account, a.canWrite {
            Label("Signed in as \(a.name ?? "you")", systemImage: "person.crop.circle.badge.checkmark")
        } else if let a = queue.account, a.signedIn {
            Label("\(a.name ?? "This account") can look at photos but not add them.", systemImage: "person.crop.circle.badge.exclamationmark")
        } else if queue.offline {
            Label("iopix can't be reached right now.", systemImage: "wifi.exclamationmark")
        } else {
            Label("Sign in on the iopix page first. Photos wait here until you do.", systemImage: "person.crop.circle.badge.questionmark")
        }
    }

    private func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        loading = true
        Task {
            var files: [URL] = []
            for item in items {
                if let f = try? await item.loadTransferable(type: PickedFile.self) { files.append(f.url) }
            }
            queue.add(files: files, move: true)
            picked = []
            loading = false
        }
    }

    private func saveServer() {
        guard let url = AppConfig.normalisedServer(serverText) else { serverText = AppConfig.serverURL.absoluteString; return }
        if url != AppConfig.serverURL {
            AppConfig.serverURL = url
            Task { await queue.refreshAccount() }
        }
        serverText = url.absoluteString
    }
}

struct ItemRow: View {
    let item: UploadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name).lineLimit(1).truncationMode(.middle)
            if item.state == .sending {
                ProgressView(value: item.progress)
            } else {
                Text(item.stateText).font(.caption).foregroundStyle(item.state == .failed ? .red : .secondary)
            }
        }
    }
}
