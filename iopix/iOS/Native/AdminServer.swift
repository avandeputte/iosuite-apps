import SwiftUI

/// Settings › Backups: ioPix's own data to download (digiKam's database, ioPix's database and search index). The
/// suite's server (version, updates, MCP, log, restart) is the start page's Settings, not ioPix's.
struct AdminBackupsScreen: View {
    @ObservedObject var model: AdminModel
    @StateObject private var notice = AdminNotice()
    @State private var sharing: AdminSharedFile?
    @State private var downloading: String?

    private var appName: String { model.appName }

    var body: some View {
        Form {
            let noDigikam = model.m.dict("digikam").bool("none")
            Section {
                if !noDigikam {
                    Button(downloading == "digikam" ? "Preparing…" : "digiKam database") { Task { await fetch("api/backup/digikam", "digikam-backup", tag: "digikam") } }
                }
                Button(downloading == "app" ? "Preparing…" : "\(appName) data (zip)") { Task { await fetch("api/backup/app", "iopix-data.zip", tag: "app") } }
            } footer: {
                Text((noDigikam ? "\(appName)’s database and search index, as a zip." : "digiKam’s database as it is now, and \(appName)’s database and search index as a zip.")
                     + " The server's version, updates and log are in the start page's Settings.")
            }
            .disabled(downloading != nil)
        }
        .navigationTitle("Backups")
        .sheet(item: $sharing, onDismiss: { if let f = sharing { try? FileManager.default.removeItem(at: f.url.deletingLastPathComponent()) } }) { ShareSheet(items: [$0.url]) }
        .adminNotice(notice)
    }

    /// The server makes the backup when asked with a POST (it writes a large dump), and sends it back.
    private func fetch(_ path: String, _ name: String, tag: String) async {
        downloading = tag
        defer { downloading = nil }
        do { sharing = AdminSharedFile(url: try await AdminAPI.download(path, fallbackName: name, method: "POST")) } catch { notice.fail(error) }
    }
}
