import SwiftUI

@MainActor
struct LoginView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: Field?
    @State private var username = ""
    @State private var password = ""

    private enum Field { case username, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image("BrandMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .padding(.top, 42)
                    Text("航的助手")
                        .font(.system(size: 30, weight: .bold))
                    Text("登录教务账号，查看今日课程")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 14) {
                        TextField("账号", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focusedField, equals: .username)
                            .onSubmit { focusedField = .password }
                        SecureField("密码", text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focusedField, equals: .password)
                            .onSubmit { submit() }
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 12)

                    if let error = state.loginError {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(action: submit) {
                        Group {
                            if state.isLoginSubmitting { ProgressView().tint(.white) }
                            else { Text("登录").fontWeight(.semibold) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isLoginSubmitting || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(colorScheme == .dark ? DesignTokens.darkBackground : DesignTokens.lightBackground)
            .navigationTitle("账号登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { state.isLoginPresented = false } } }
        }
    }

    private func submit() {
        guard !state.isLoginSubmitting else { return }
        focusedField = nil
        Task { await state.login(username: username, password: password) }
    }
}
