import SwiftUI

@MainActor
struct LoginView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
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
            .onChange(of: state.loginFailureFeedback?.id) { _, eventID in
                guard let event = state.loginFailureFeedback, event.id == eventID else { return }
                AppHaptics.trigger(event.feedback.hapticInteraction)
            }
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
            FloatingLoginField(title: "账号", symbol: "person",
                               isFocused: focusedField == .username, text: username, trailingInset: 18,
                               onTapToFocus: { focusedField = .username }) {
                TextField("", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
                    .id(Field.username)
            } trailing: {
                EmptyView()
            }

            Divider().padding(.leading, 56)

            FloatingLoginField(title: "密码", symbol: "lock",
                               isFocused: focusedField == .password, text: password, trailingInset: 6,
                               onTapToFocus: { focusedField = .password }) {
                Group {
                    if showsPassword {
                        TextField("", text: $password)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .focused($focusedField, equals: .password)
                            .onSubmit(submit)
                    } else {
                        SecureField("", text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focusedField, equals: .password)
                            .onSubmit(submit)
                    }
                }
                .id(Field.password)
            } trailing: {
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
        }
        .font(.body)
        .background(credentialsBackground)
    }

    @ViewBuilder
    private var credentialsBackground: some View {
        if #available(iOS 26.0, *), !reduceTransparency, colorSchemeContrast != .increased {
            Color.clear
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            Color(uiColor: .secondarySystemGroupedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var loginButton: some View {
        GeometryReader { proxy in
            let isSubmitting = state.isLoginSubmitting
            loginButtonControl(isSubmitting: isSubmitting)
                .frame(
                    width: LoginButtonPresentation.width(
                        isSubmitting: isSubmitting,
                        availableWidth: proxy.size.width
                    ),
                    height: LoginButtonPresentation.height
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: LoginButtonPresentation.morphDuration),
                    value: isSubmitting
                )
        }
        .frame(height: LoginButtonPresentation.height)
    }

    @ViewBuilder
    private func loginButtonControl(isSubmitting: Bool) -> some View {
        let button = Button(action: submit) {
            ZStack {
                if isSubmitting {
                    ProgressView()
                        .tint(.white)
                        .transition(.opacity)
                } else {
                    Text("登录")
                        .transition(.opacity)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: LoginButtonPresentation.contentDuration),
                value: isSubmitting
            )
        }
        .disabled(isSubmitting || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
        .accessibilityLabel(isSubmitting ? "正在登录" : "登录")
        .tint(DesignTokens.brand)
        .buttonBorderShape(.roundedRectangle(radius: LoginButtonPresentation.cornerRadius(isSubmitting: isSubmitting)))

        if #available(iOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
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

enum FloatingLabelState {
    static func shouldFloat(text: String, isFocused: Bool) -> Bool {
        isFocused || !text.isEmpty
    }
}

enum LoginButtonPresentation {
    static let height: CGFloat = 56
    static let morphDuration: Double = 0.22
    static let contentDuration: Double = 0.14

    static func width(isSubmitting: Bool, availableWidth: CGFloat) -> CGFloat {
        isSubmitting ? height : availableWidth
    }

    static func cornerRadius(isSubmitting: Bool) -> CGFloat {
        isSubmitting ? height / 2 : 18
    }
}

private struct FloatingLoginField<Content: View, Trailing: View>: View {
    let title: String
    let symbol: String
    let isFocused: Bool
    let text: String
    let trailingInset: CGFloat
    let onTapToFocus: () -> Void
    let content: Content
    let trailing: Trailing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var labelInset = 13

    init(title: String, symbol: String, isFocused: Bool, text: String, trailingInset: CGFloat,
         onTapToFocus: @escaping () -> Void,
         @ViewBuilder content: () -> Content,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.symbol = symbol
        self.isFocused = isFocused
        self.text = text
        self.trailingInset = trailingInset
        self.onTapToFocus = onTapToFocus
        self.content = content()
        self.trailing = trailing()
    }

    private var isFloating: Bool {
        FloatingLabelState.shouldFloat(text: text, isFocused: isFocused)
    }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                ZStack(alignment: .topLeading) {
                    content
                        .accessibilityLabel(title)
                        .padding(.top, labelInset)
                        .frame(minHeight: 48, alignment: .bottom)

                    Text(title)
                        .font(.body)
                        .foregroundStyle(isFocused ? DesignTokens.brand : .secondary)
                        .scaleEffect(isFloating ? 0.76 : 1, anchor: .leading)
                        .offset(y: isFloating ? 1 : labelInset + 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                guard !isFocused else { return }
                onTapToFocus()
            })

            trailing
        }
        .padding(.leading, 18)
        .padding(.trailing, trailingInset)
        .padding(.vertical, 6)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isFloating)
    }
}
