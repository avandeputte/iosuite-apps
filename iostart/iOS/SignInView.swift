import SwiftUI

/// The sign-in of the ioSuite apps (shared/DeviceSignIn): the server's address for apps, the name and password,
/// and the code of two-step sign-in when the account has it. This phone gets an app password of its own.
struct SignInView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            DeviceSignInForm(app: .iostart) { answer in
                Task { await model.signedIn(Account(answer.credential)) }
            }
            .safeAreaInset(edge: .top) {
                HStack(spacing: 12) {
                    Image("Mark")
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading) {
                        Text("ioStart").font(.title2.bold())
                        Text("Your start page's bookmarks, your day and your tasks.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
