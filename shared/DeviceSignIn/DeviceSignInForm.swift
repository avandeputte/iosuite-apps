import SwiftUI

/// The sign-in screen of the ioSuite apps, the same in each: the server's address for apps, the name, the password,
/// and the code of two-step sign-in once the server asks for it. Put it in a NavigationStack, a sheet or a window.
struct DeviceSignInForm: View {
    let app: DeviceApp
    /// Called on the main actor once signed in; the credential is already saved.
    let onSignedIn: (DeviceSignIn.Answer) -> Void
    var onCancel: (() -> Void)? = nil

    @State private var address = ""
    @State private var name = ""
    @State private var password = ""
    @State private var code = ""
    @State private var askCode = false
    @State private var working = false
    @State private var failure: String?
    @State private var filled = false

    private enum Field { case address, name, password, code }
    @FocusState private var focus: Field?

    var body: some View {
        Form {
            Section {
                TextField("Server address", text: $address, prompt: Text("https://start-api.example.com"))
                    .focused($focus, equals: .address)
                    #if os(iOS)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .onSubmit { focus = .name }
            } header: {
                Text("Server")
            } footer: {
                Text(DeviceSignIn.addressHint)
            }

            Section {
                TextField("Name", text: $name)
                    .textContentType(.username)
                    .focused($focus, equals: .name)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .onSubmit { focus = .password }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .onSubmit { askCode ? (focus = .code) : go() }
                if askCode {
                    TextField("Code", text: $code)
                        .textContentType(.oneTimeCode)
                        .focused($focus, equals: .code)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit(go)
                }
            } header: {
                Text("Account")
            } footer: {
                Text(askCode ? "Two-step sign-in is on for this account: enter the code from your code app (or a recovery code)." : DeviceSignIn.explanation)
            }

            Section {
                Button(action: go) {
                    HStack {
                        if working { ProgressView() }
                        Text(working ? "Signing In…" : "Sign In")
                    }
                }
                .disabled(working || address.trimmingCharacters(in: .whitespaces).isEmpty || name.isEmpty || password.isEmpty
                          || (askCode && code.trimmingCharacters(in: .whitespaces).isEmpty))
                if let onCancel {
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                if let failure {
                    Text(failure).foregroundStyle(.red).font(.callout)
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .onAppear {
            guard !filled else { return }
            filled = true
            let store = DeviceCredentialStore(app: app)
            address = store.lastAddress ?? ""
            name = store.lastName ?? ""
            focus = address.isEmpty ? .address : name.isEmpty ? .name : .password
        }
    }

    private func go() {
        guard !working else { return }
        failure = nil
        working = true
        let typedAddress = address, typedName = name, typedPassword = password, typedCode = askCode ? code : nil
        Task { @MainActor in
            defer { working = false }
            do {
                let answer = try await DeviceSignIn.signIn(app: app, address: typedAddress, name: typedName, password: typedPassword, code: typedCode)
                DeviceCredentialStore(app: app).save(answer.credential)
                password = ""
                code = ""
                onSignedIn(answer)
            } catch DeviceSignInError.needsCode(let why) {
                if askCode { failure = why.isEmpty ? "That code is not right." : why }
                askCode = true
                code = ""
                focus = .code
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
