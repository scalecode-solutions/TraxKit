import SwiftUI

/// TraxLab login — authenticates against mvServer via MvAuth, then hands off to
/// the location map. Use real mvchat credentials; the same account's JWT is what
/// mvTrax validates. Defaults to Production (api.mvchat.app + trax.mvchat.app);
/// the picker can switch to Local for development.
struct LoginView: View {
    let auth: AuthModel

    @State private var server: LabServer = .production
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    private var canSubmit: Bool {
        !username.isEmpty && !password.isEmpty && !auth.isLoggingIn
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.tardisBlue)
                Text("Trax")
                    .font(.largeTitle.bold())
                Text("Sign in with your mvchat account")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                Picker("Server", selection: $server) {
                    ForEach(LabServer.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                TextField("Username, handle, or email", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
                    .padding(12)
                    .background(.quaternary, in: .rect(cornerRadius: 10))

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit { submit() }
                    .padding(12)
                    .background(.quaternary, in: .rect(cornerRadius: 10))

                if case .failed(let message) = auth.state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: submit) {
                    HStack {
                        if auth.isLoggingIn { ProgressView().tint(.white) }
                        Text(auth.isLoggingIn ? "Signing in…" : "Sign In")
                            .bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.tardisBlue)
                .disabled(!canSubmit)
            }

            Spacer()
            Spacer()
        }
        .padding(28)
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        Task { await auth.login(server: server, username: username, password: password) }
    }
}
