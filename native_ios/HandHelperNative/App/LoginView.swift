import SwiftUI

@MainActor
struct LoginView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var state: AppState
    @FocusState private var focusedField: Field?
    @State private var username = ""
    @State private var password = ""
    @State private var showsPassword = false

    private enum Field: Hashable { case username, password }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        appearanceMenu
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        Image("BrandMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .accessibilityHidden(true)
                            .padding(.top, 20)

                        Text("欢迎回来")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DesignTokens.brand)
                            .padding(.top, 18)
                        Text("航的助手")
                            .font(.title.bold())
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)

                        credentials
                            .padding(.top, 32)

                        Text(state.loginError ?? " ")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)
                            .opacity(state.loginError == nil ? 0 : 1)
                            .accessibilityHidden(state.loginError == nil)
                            .padding(.top, 4)

                        loginButton
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: focusedField) { _, field in
                    guard let field else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        scroll.scrollTo(field, anchor: .center)
                    }
                }
            }
            .background(loginBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var loginBackground: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            if !reduceTransparency && colorSchemeContrast != .increased {
                LinearGradient(
                    colors: [DesignTokens.brand.opacity(colorScheme == .dark ? 0.06 : 0.045), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private var credentials: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "person")
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("账号", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
                    .id(Field.username)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)

            Divider().padding(.leading, 56)

            HStack(spacing: 14) {
                Image(systemName: "lock")
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Group {
                    if showsPassword {
                        TextField("密码", text: $password)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .focused($focusedField, equals: .password)
                            .onSubmit(submit)
                    } else {
                        SecureField("密码", text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focusedField, equals: .password)
                            .onSubmit(submit)
                    }
                }
                .id(Field.password)

                Button {
                    let wasFocused = focusedField == .password
                    showsPassword.toggle()
                    if wasFocused {
                        Task { @MainActor in
                            await Task.yield()
                            focusedField = .password
                        }
                    }
                } label: {
                    Image(systemName: showsPassword ? "eye.slash" : "eye")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(showsPassword ? "隐藏密码" : "显示密码")
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
        }
        .font(.body)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20))
    }

    private var loginButton: some View {
        let button = Button(action: submit) {
            ZStack {
                Text("登录")
                    .opacity(state.isLoginSubmitting ? 0 : 1)
                ProgressView()
                    .tint(.white)
                    .opacity(state.isLoginSubmitting ? 1 : 0)
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .disabled(state.isLoginSubmitting || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
        .accessibilityLabel(state.isLoginSubmitting ? "正在登录" : "登录")
        .tint(DesignTokens.brand)

        return Group {
            if #available(iOS 26.0, *) {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.borderedProminent)
            }
        }
    }

    private var appearanceMenu: some View {
        let menu = Menu {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                Button {
                    state.setAppearance(mode)
                } label: {
                    Label(appearanceTitle(for: mode), systemImage: state.appearance == mode ? "checkmark" : "circle")
                }
            }
        } label: {
            Image(systemName: "circle.lefthalf.filled")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel("外观设置")
        .buttonBorderShape(.circle)

        return Group {
            if #available(iOS 26.0, *) {
                menu.buttonStyle(.glass)
            } else {
                menu.buttonStyle(.bordered)
            }
        }
    }

    private func appearanceTitle(for mode: AppearanceMode) -> String {
        switch mode {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    private func submit() {
        guard !state.isLoginSubmitting else { return }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            focusedField = .username
            return
        }
        guard !password.isEmpty else {
            focusedField = .password
            return
        }
        focusedField = nil
        let enteredUsername = username
        let enteredPassword = password
        Task { await state.login(username: enteredUsername, password: enteredPassword) }
    }
}
