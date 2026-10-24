import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

@main
struct IopixMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var queue = UploadQueue.shared
    @StateObject private var watcher = PhotosWatcher.shared

    var body: some Scene {
        Window("iopix", id: "main") {
            MainWindow()
                .environmentObject(queue)
                .environmentObject(watcher)
        }
        .defaultSize(width: 1280, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Send Files…") { queue.add(files: MacFiles.choose()) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuView()
                .environmentObject(queue)
                .environmentObject(watcher)
                .task { await queue.refreshAccount() }
        } label: {
            MenuBarIcon(queue: queue)
        }
        .menuBarExtraStyle(.window)

        Window("Import Photos", id: "card") {
            CardImportView()
        }
        .defaultSize(width: 760, height: 560)
        .commandsRemoved()

        Window("Sign in to iopix", id: "signin") {
            SignInView().environmentObject(queue)
        }
        .defaultSize(width: 520, height: 720)

        Window("New photos", id: "review") {
            ReviewView().environmentObject(queue)
                .frame(minWidth: 480, minHeight: 400)
        }
        .defaultSize(width: 640, height: 560)

        Window("iopix Settings", id: "settings") {
            SettingsView().environmentObject(queue).environmentObject(watcher)
        }
        .windowResizability(.contentSize)
    }
}

/// The menu bar icon; it is always there, so it hands the window opener to the Router.
struct MenuBarIcon: View {
    @ObservedObject var queue: UploadQueue
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: !queue.pending.isEmpty ? "arrow.up.circle" : !queue.reviewing.isEmpty ? "photo.badge.plus"
              : queue.needsSignIn ? "photo.badge.exclamationmark" : "photo.stack")
            .onAppear { Router.openWindow = openWindow }
    }
}

struct MenuView: View {
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var watcher: PhotosWatcher
    @Environment(\.openWindow) private var openWindow
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Brand.name(onLight: true).font(.headline)
                Spacer()
                account
            }

            if queue.needsSignIn && queue.account?.signedIn != true {
                HStack {
                    Text(queue.pending.isEmpty ? "Sign in to send photos." : "Sign in to send the \(queue.pending.count) waiting.")
                    Spacer()
                    Button("Sign in…") { show("signin") }
                }
                .font(.callout)
            }

            Toggle(isOn: Binding(get: { watcher.enabled }, set: { on in Task { await watcher.setEnabled(on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Look for new photos in Photos")
                    Text(watcher.note ?? "Photos and videos added to your library from now on are listed here, and you pick which ones go to iopix.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if !queue.reviewing.isEmpty {
                HStack {
                    Image(systemName: "photo.badge.plus").foregroundStyle(Color.accentColor)
                    Text("\(queue.reviewing.count) new photo\(queue.reviewing.count == 1 ? "" : "s") to look at")
                    Spacer()
                    Button("Review…") { show("review") }.keyboardShortcut(.defaultAction)
                }
            }

            dropZone

            if let why = queue.blocked {
                Text(why).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Goes to \(Destination.current.example()) in iopix").font(.caption).foregroundStyle(.secondary)
            }

            if let item = queue.current {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sending \(item.name)").lineLimit(1).truncationMode(.middle)
                    ProgressView(value: item.progress)
                    if queue.pending.count > 1 { Text("\(queue.pending.count - 1) more waiting").font(.caption).foregroundStyle(.secondary) }
                }
            } else if !queue.pending.isEmpty {
                Text("\(queue.pending.count) waiting\(queue.offline ? " for a connection" : "")").foregroundStyle(.secondary)
            }

            if !queue.finished.isEmpty {
                Divider()
                ForEach(queue.finished.prefix(5)) { item in
                    HStack {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(item.stateText).foregroundStyle(item.state == .failed ? .red : .secondary).lineLimit(1)
                    }
                    .font(.caption)
                }
                HStack {
                    if queue.finished.contains(where: { $0.state == .failed }) { Button("Try again") { queue.retryFailed() } }
                    Spacer()
                    Button("Clear list") { queue.clearFinished() }
                }
                .buttonStyle(.link).font(.caption)
            }

            Divider()
            HStack {
                Button("Open iopix") { show("main") }
                Button("Settings…") { show("settings") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder private var account: some View {
        if let a = queue.account, a.canWrite {
            Text(a.name ?? "Signed in").font(.caption).foregroundStyle(.secondary)
        } else if let a = queue.account, a.signedIn {
            Text("\(a.name ?? "This account") can't add photos").font(.caption).foregroundStyle(.orange)
        } else if queue.offline {
            Text("Can't reach iopix").font(.caption).foregroundStyle(.orange)
        } else {
            Button("Sign in…") { show("signin") }.buttonStyle(.link).font(.caption)
        }
    }

    private var dropZone: some View {
        Button(action: pickFiles) {
            VStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up").font(.title2)
                Text("Drop photos here, or click to choose")
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(dropping ? Color.accentColor : Color.secondary.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in queue.add(files: Self.expand(url)) }
                }
            }
            return true
        }
    }

    private func pickFiles() { queue.add(files: MacFiles.choose()) }

    /// A dropped folder stands for the photos and videos in it (and its subfolders).
    static func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [url] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles])
        var out: [URL] = []
        while let f = walker?.nextObject() as? URL {
            if let t = try? f.resourceValues(forKeys: [.contentTypeKey]).contentType, t.conforms(to: .image) || t.conforms(to: .movie) {
                out.append(f)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SignInView: View {
    @EnvironmentObject private var queue: UploadQueue
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            IopixWebView(url: AppConfig.serverURL) { Task { await queue.refreshAccount() } }
            Divider()
            HStack {
                if let a = queue.account, a.canWrite {
                    Label("Signed in as \(a.name ?? "you"). Photos can be sent now.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Close") { dismissWindow(id: "signin") }.keyboardShortcut(.defaultAction)
                } else if let a = queue.account, a.signedIn {
                    Text("\(a.name ?? "This account") can look at photos but not add them. Sign in with another account.")
                    Spacer()
                } else {
                    Text("Sign in on the page above, the way you do in the browser.")
                    Spacer()
                }
            }
            .padding(10)
            .font(.callout)
        }
        .frame(minWidth: 420, minHeight: 520)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var watcher: PhotosWatcher
    @Environment(\.openWindow) private var openWindow
    @State private var serverText = AppConfig.serverURL.absoluteString
    @State private var tokenID = ServiceToken.clientID ?? ""
    @State private var tokenSecret = ServiceToken.clientSecret ?? ""
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?
    @State private var saved = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            SourcesSettings().tabItem { Label("Sources", systemImage: "tray.and.arrow.down") }
            DesktopSettings().tabItem { Label("Desktop", systemImage: "photo.on.rectangle") }
            OfflineSettings().tabItem { Label("Offline", systemImage: "arrow.down.circle") }
        }
        .frame(width: 520)
    }

    private var general: some View {
        Form {
            Section {
                TextField("Server address", text: $serverText)
                    .onSubmit(save)
                HStack {
                    if let a = queue.account, a.signedIn {
                        Text("Signed in as \(a.name ?? "you")").foregroundStyle(.secondary)
                        Spacer()
                        Button("Sign out") {
                            Task {
                                await IopixClient.shared.signOut()
                                await CookieSync.clearWebView()
                                await queue.refreshAccount()
                            }
                        }
                    } else {
                        Text("Not signed in").foregroundStyle(.secondary)
                        Spacer()
                        Button("Sign in…") { openWindow(id: "signin") }
                    }
                }
            }

            DestinationSection()

            Section {
                TextField("Client ID", text: $tokenID)
                SecureField("Client secret", text: $tokenSecret)
            } header: {
                Text("Cloudflare service token (optional)")
            } footer: {
                Text("Cloudflare's sign-in runs out after a while. With a service token, photos keep going through Cloudflare without it; you still sign in to iopix once. You can also use the server's address on your home network instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at login", isOn: $atLogin)
                    .onChange(of: atLogin) { _, on in setLogin(on) }
                if let loginNote { Text(loginNote).font(.caption).foregroundStyle(.orange) }
                if watcher.enabled {
                    Button("Also list the photos of the last 7 days") { watcher.sendRecent(days: 7) }
                }
            }

            HStack {
                Spacer()
                if saved { Text("Saved").foregroundStyle(.secondary) }
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        if let url = AppConfig.normalisedServer(serverText) {
            AppConfig.serverURL = url
            serverText = url.absoluteString
        } else {
            serverText = AppConfig.serverURL.absoluteString
        }
        ServiceToken.clientID = tokenID.trimmingCharacters(in: .whitespaces)
        ServiceToken.clientSecret = tokenSecret.trimmingCharacters(in: .whitespaces)
        saved = true
        Task {
            await queue.refreshAccount()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saved = false
        }
    }

    private func setLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        guard on != (service.status == .enabled) else { return }  // the toggle was only put back after a failure
        do {
            if on { try service.register() } else { try service.unregister() }
            loginNote = service.status == .requiresApproval ? "Allow iopix under System Settings › General › Login Items." : nil
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            loginNote = "macOS did not allow it: \(error.localizedDescription)"
            atLogin = service.status == .enabled
        }
    }
}
