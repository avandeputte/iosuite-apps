import SwiftUI

/// The sign-in, the same as in the other ioSuite apps (shared/DeviceSignIn): the server's address for apps, name,
/// password, and the code of two-step sign-in when the account has it on. Shown on first launch, and again (with the
/// address and name filled in) when the server no longer takes this device's password.
struct SignInView: View {
    var cancellable = true
    var done: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var queue: UploadQueue

    var body: some View {
        NavigationStack {
            DeviceSignInForm(app: AppConfig.deviceApp, onSignedIn: { answer in
                IopixClient.shared.signedIn(answer.credential)
                ImageCache.shared.removeAll()
                Task { await queue.refreshAccount() }
                done()
                if cancellable { dismiss() }
            })
            .navigationTitle("Sign in to ioPix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if cancellable {
                    ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Cancel") } }
                }
            }
        }
    }
}
