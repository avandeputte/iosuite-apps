import SwiftUI

@main
struct IopixTVApp: App {
    var body: some Scene {
        WindowGroup { TVRoot() }
    }
}

/// Sign-in, then the library.
struct TVRoot: View {
    enum Step { case checking, signIn, library }
    @State private var step: Step = IopixClient.shared.isSignedIn ? .checking : .signIn

    var body: some View {
        Group {
            switch step {
            case .checking:
                ProgressView().task { await check() }
            case .signIn:
                TVSignIn { step = .library }
            case .library:
                TVLibrary(signedOut: { step = .signIn }, switchProfile: { step = .signIn })
                    .preferredColorScheme(.dark)  // the pages sit on a dark photo whatever the TV's appearance setting
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .iopixSignedOut)) { _ in step = .signIn }
    }

    private func check() async {
        do {
            let a = try await IopixClient.shared.account()
            // more than one person has used this TV: ask who is watching (no password for someone signed in before)
            let ask = TVPrefs.shared.askWhoIsWatching && Profiles.names.count > 1
            step = a.signedIn && !ask ? .library : .signIn
        } catch {
            step = .signIn  // shows the problem there
        }
    }
}

/// Who's watching: the people who signed in on this TV before (no password needed), and the sign-in for someone else,
/// the same as in the other ioSuite apps.
struct TVSignIn: View {
    let done: () -> Void
    @State private var problem: String?
    @State private var someoneElse = Profiles.names.isEmpty

    var body: some View {
        if someoneElse {
            VStack(spacing: 30) {
                Brand.name().font(.system(size: 60, weight: .bold))
                DeviceSignInForm(app: AppConfig.deviceApp, onSignedIn: { answer in
                    IopixClient.shared.signedIn(answer.credential)
                    Profiles.save(answer.credential)
                    done()
                }, onCancel: Profiles.names.isEmpty ? nil : { someoneElse = false })
                .frame(width: 1100)
            }
        } else {
            VStack(spacing: 40) {
                VStack(spacing: 10) { Brand.name().font(.system(size: 76, weight: .bold)); Text("Who's watching?").font(.title2.bold()) }
                HStack(spacing: 40) {
                    ForEach(Profiles.names, id: \.self) { name in
                        Button { Task { await use(name) } } label: {
                            VStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.fill").font(.system(size: 90))
                                Text(name)
                            }
                            .frame(width: 240, height: 220)
                        }
                        .buttonStyle(.card)
                    }
                    Button { someoneElse = true } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 90))
                            Text("Someone else")
                        }
                        .frame(width: 240, height: 220)
                    }
                    .buttonStyle(.card)
                }
                if let problem { Text(problem).foregroundStyle(.red).multilineTextAlignment(.center) }
            }
        }
    }

    /// Someone who signed in on this TV before: their app password is put back.
    private func use(_ name: String) async {
        problem = nil
        guard Profiles.use(name) else { someoneElse = true; return }
        do {
            _ = try await IopixClient.shared.account()
            done()
        } catch IopixError.needsSignIn {
            Profiles.forget(name)  // the password was removed on the server: sign in again
            problem = "\(name) needs to sign in again."
            someoneElse = true
        } catch {
            problem = "ioPix can't be reached: \(error.localizedDescription)"
        }
    }
}
