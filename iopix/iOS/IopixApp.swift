import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreSpotlight
import UserNotifications

/// iOS wakes the app when background sending finishes (also the share sheet's): the uploads pick their results up.
final class IopixAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        BackgroundUploads.wakeHandlers[identifier] = completionHandler
        _ = BackgroundUploads.shared(identifier)
    }
}

@main
struct IopixApp: App {
    @UIApplicationDelegateAdaptor(IopixAppDelegate.self) private var appDelegate
    @StateObject private var queue = UploadQueue.shared
    @StateObject private var watcher = PhotosWatcher.shared
    @StateObject private var launch = LaunchState()
    @Environment(\.scenePhase) private var phase
    @AppStorage("iopix.pref.theme") private var theme = "system"

    init() {
        UploadQueue.shared.startBackground()
        NetworkRoute.shared.start()
        #if targetEnvironment(macCatalyst)
        UNUserNotificationCenter.current().delegate = MacNotifier.shared  // early: a clicked banner can start the app
        Task { @MainActor in
            MacMenuBar.shared.start()
            MacExtras.start()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(theme == "dark" ? .dark : theme == "light" ? .light : nil)  // the Display setting
                .macTextSelection()
                .environmentObject(queue)
                .environmentObject(watcher)
                .environmentObject(launch)
        }
        .commands {  // iPad with a keyboard; off until a server address has been entered
            CommandGroup(after: .newItem) {
                Button("Send Photos…") { NotificationCenter.default.post(name: .iopixSendPhotos, object: nil) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(!launch.hasServer)
            }
            CommandGroup(after: .toolbar) {
                Button("Reload") { NotificationCenter.default.post(name: .iopixReload, object: nil) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!launch.hasServer)
            }
        }
        .onChange(of: phase) { _, now in
            guard now == .active else { return }
            NotificationCenter.default.post(name: .iopixBecameActive, object: nil)
            watcher.checkNow()
            Task { await queue.refreshAccount() }
        }
    }
}

/// Whether this device is signed in (the first launch, and a password removed on the server, show the sign-in).
final class LaunchState: ObservableObject {
    @Published var hasServer = IopixClient.shared.isSignedIn
}

struct RootView: View {
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var launch: LaunchState
    @StateObject private var store = LibraryStore()
    @StateObject private var router = Router.shared
    @State private var showUploads = false
    @State private var server = AppConfig.serverURL

    @State private var signingIn = false
    @State private var showCards = false
    @State private var dropping = false

    var body: some View {
        Group {
            if launch.hasServer {
                library
            } else {
                SignInView(cancellable: false) {
                    launch.hasServer = true
                    if server != AppConfig.serverURL {  // another server or account: start afresh
                        server = AppConfig.serverURL
                        Router.shared.photosPath = []; Router.shared.morePath = []
                    }
                    Task { await store.load() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .iopixSignedOut)) { _ in
            launch.hasServer = false  // the sign-in comes back, with the address and name filled in
        }
    }

    private var library: some View {
        AppTabs { showUploads = true }
            .environmentObject(store)
            .environmentObject(router)
            .onReceive(NotificationCenter.default.publisher(for: .iopixBecameActive)) { _ in
                if store.problem != nil, !store.needsSignIn { Task { await store.load() } }
                Task { await HomeServer.shared.check() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .iopixNetworkMoved)) { _ in
                // left home (or came back): the home address may answer now, or no longer
                HomeServer.shared.forget()
                Task {
                    await store.load()
                    await queue.refreshAccount()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .iopixSendPhotos)) { _ in showUploads = true }
            .onReceive(NotificationCenter.default.publisher(for: .iopixSignIn)) { _ in signingIn = true }
            #if targetEnvironment(macCatalyst)
            .onReceive(NotificationCenter.default.publisher(for: .iopixCards)) { _ in showCards = true }
            .sheet(isPresented: $showCards) { MacCardImportSheet() }
            #endif
            // iopix-native://photo/<id> (the widget), ://review, ://today
            .onOpenURL { url in
                guard url.scheme == "iopix-native" else { return }
                switch url.host {
                case "photo": if let id = Int(url.lastPathComponent) { router.open("#/photos?ids=\(id)") }
                case "review": showUploads = true
                case "today":
                    let c = Calendar.current.dateComponents([.month, .day], from: Date())
                    router.open(String(format: "#/photos?md=%02d-%02d", c.month ?? 1, c.day ?? 1))
                default: break
                }
            }
            // a Spotlight result: its id is the page of the library to open
            .onContinueUserActivity(CSSearchableItemActionType) { a in
                if let route = a.userInfo?[CSSearchableItemActivityIdentifier] as? String { router.open(route) }
            }
            .sheet(isPresented: $signingIn) { SignInView { showUploads = true }.environmentObject(queue) }
            // photos dragged in from Photos or Files (iPad side by side) go to the queue
            .dropDestination(for: PickedFile.self) { files, _ in
                queue.add(files: files.map(\.url), move: true)
                return true
            } isTargeted: { dropping = $0 }
            .overlay { if dropping { DropHint() } }
            .sheet(isPresented: $showUploads) {
                UploadsView()
            }
    }

    private var uploadButton: some View {
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
        .accessibilityLabel("Send photos to ioPix")
        .padding(.trailing, 16)
        .padding(.bottom, 64)
    }
}

/// A photo or video picked from the library, as its original file.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        // the photo first: a Live Photo offers both a still and a short movie, and the still is the picture
        FileRepresentation(importedContentType: .image) { try PickedFile(copying: $0.file) }
        FileRepresentation(importedContentType: .movie) { try PickedFile(copying: $0.file) }
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
    @State private var pickNote: String?
    @State private var signingIn = false
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
                    if let pickNote { Text(pickNote).font(.footnote).foregroundStyle(.orange) }
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
                    Text(watcher.note ?? "Photos and videos you take from now on are listed here when you open ioPix, and you pick which ones to send. Photos already in ioPix are skipped.")
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

                ServerSection { dismiss() }

                Section {
                    DisclosureGroup("Cloudflare Access service token") {
                        TextField("Client ID", text: $tokenID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Client secret", text: $tokenSecret)
                        Button("Save token") {
                            ServiceToken.clientID = tokenID.trimmingCharacters(in: .whitespaces)
                            ServiceToken.clientSecret = tokenSecret.trimmingCharacters(in: .whitespaces)
                            Task { await queue.refreshAccount() }
                        }
                    }
                } footer: {
                    Text("Only if your server is behind Cloudflare Access; leave it empty otherwise.")
                }
            }
            .navigationTitle("Send to ioPix")
            .toolbar { ToolbarItem(placement: .principal) { Brand.text("Send to ", onLight: true).font(.headline) } }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { BarText("Done") } }
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
            Label("ioPix can't be reached right now.", systemImage: "wifi.exclamationmark")
        } else {
            Button { signingIn = true } label: {
                Label("Sign in to ioPix… Photos wait here until you do.", systemImage: "person.crop.circle.badge.questionmark")
            }
            .sheet(isPresented: $signingIn) { SignInView().environmentObject(queue) }
        }
    }

    private func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        loading = true
        Task {
            var files: [URL] = []
            var failed = 0
            for item in items {
                if let f = try? await item.loadTransferable(type: PickedFile.self) { files.append(f.url) } else { failed += 1 }
            }
            queue.add(files: files, move: true)
            if failed > 0 { pickNote = failed == 1 ? "One photo couldn't be read (not downloaded from iCloud?)." : "\(failed) photos couldn't be read (not downloaded from iCloud?)." }
            picked = []
            loading = false
        }
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

extension Notification.Name {
    static let iopixBecameActive = Notification.Name("iopixBecameActive")
}

extension Notification.Name {
    /// Asks the app to show the sign-in (the Mac menu bar's "Sign in…").
    static let iopixSignIn = Notification.Name("iopixSignIn")
}
