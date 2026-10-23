import SwiftUI

@MainActor
struct LoginView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: Field?
    @State private var username = ""
    @State private var password = ""
    @State private var showsPassword = false

    private enum Field { case username, password }
    private var dark: Bool { colorScheme == .dark }
    private let blue = Color(red: 10 / 255, green: 132 / 255, blue: 1)

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let compact = geometry.size.height < 700
                ScrollView {
                    VStack(spacing: 0) {
                        themeButton
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Image("BrandMark")
                            .resizable().scaledToFit()
                            .frame(width: compact ? 64 : 76, height: compact ? 64 : 76)
                            .clipShape(RoundedRectangle(cornerRadius: compact ? 19 : 22))
                            .shadow(color: blue.opacity(dark ? 0.2 : 0.25), radius: 18, y: 12)
                            .padding(.top, compact ? 19 : 37)
                        Text("欢迎回来")
                            .font(.system(size: 13, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(dark ? TodayStyle.color(0x69adff) : TodayStyle.color(0x3974bf))
                            .padding(.top, 19)
                        Text("航的助手")
                            .font(.system(size: compact ? 27 : 30, weight: .heavy))
                            .tracking(-0.9)
                            .foregroundStyle(dark ? TodayStyle.color(0xf5f5f7) : TodayStyle.color(0x172033))
                            .padding(.top, 7)

                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Image(systemName: "person").frame(width: 26)
                                TextField("账号", text: $username)
                                    .foregroundStyle(dark ? TodayStyle.color(0xf5f5f7) : TodayStyle.color(0x172033))
                                    .textContentType(.username)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.next)
                                    .focused($focusedField, equals: .username)
                                    .onSubmit { focusedField = .password }
                            }
                            .frame(height: 60)
                            Divider().padding(.leading, 51)
                            HStack(spacing: 12) {
                                Image(systemName: "lock").frame(width: 26)
                                Group {
                                    if showsPassword {
                                        TextField("密码", text: $password)
                                    } else {
                                        SecureField("密码", text: $password)
                                    }
                                }
                                .foregroundStyle(dark ? TodayStyle.color(0xf5f5f7) : TodayStyle.color(0x172033))
                                .textContentType(.password)
                                .submitLabel(.go)
                                .focused($focusedField, equals: .password)
                                .onSubmit { submit() }
                                Button { showsPassword.toggle(); focusedField = .password } label: {
                                    Image(systemName: showsPassword ? "eye.slash" : "eye")
                                        .frame(width: 36, height: 44)
                                }
                                .accessibilityLabel(showsPassword ? "隐藏密码" : "显示密码")
                            }
                            .frame(height: 60)
                        }
                        .padding(.horizontal, 13)
                        .foregroundStyle(dark ? TodayStyle.color(0xa1a1a6) : TodayStyle.color(0x6b7d96))
                        .background(dark ? TodayStyle.color(0x1c1c1e, alpha: 0.87) : .white.opacity(0.76),
                                    in: RoundedRectangle(cornerRadius: 19))
                        .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(
                            dark ? .white.opacity(0.09) : TodayStyle.color(0x0f172a, alpha: 0.07)))
                        .shadow(color: .black.opacity(dark ? 0.25 : 0.06), radius: 12, y: 8)
                        .padding(.top, compact ? 38 : 60)

                        if let error = state.loginError {
                            Text(error).font(.system(size: 13)).foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 12)
                        }
                        Button(action: submit) {
                            Group {
                                if state.isLoginSubmitting { ProgressView().tint(.white) }
                                else { Text("登录").font(.system(size: 17, weight: .bold)) }
                            }
                            .frame(maxWidth: state.isLoginSubmitting ? 56 : .infinity, minHeight: 56)
                            .foregroundStyle(.white)
                            .background(blue, in: RoundedRectangle(cornerRadius: state.isLoginSubmitting ? 28 : 18))
                            .shadow(color: blue.opacity(0.25), radius: 8, y: 5)
                        }
                        .buttonStyle(.plain)
                        .disabled(state.isLoginSubmitting || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                        .animation(.easeInOut(duration: 0.22), value: state.isLoginSubmitting)
                        .padding(.top, 16)
                    }
                    .frame(maxWidth: 400)
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background {
                LinearGradient(colors: dark
                    ? [TodayStyle.color(0x080a0f), TodayStyle.color(0x10141b), TodayStyle.color(0x07080b)]
                    : [TodayStyle.color(0xf9fbff), TodayStyle.color(0xf3f7fc), TodayStyle.color(0xedf3f9)],
                    startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                GeometryReader { geometry in
                    Circle().fill(RadialGradient(colors: [blue.opacity(dark ? 0.17 : 0.22), .clear],
                                                  center: .center, startRadius: 0, endRadius: 170))
                        .frame(width: 340, height: 340)
                        .position(x: 20, y: 0)
                    Circle().fill(RadialGradient(colors: [TodayStyle.color(0x5b6fff).opacity(0.15), .clear],
                                                  center: .center, startRadius: 0, endRadius: 170))
                        .frame(width: 340, height: 340)
                        .position(x: geometry.size.width, y: geometry.size.height)
                }.ignoresSafeArea().allowsHitTesting(false)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var themeButton: some View {
        Button {
            state.setAppearance(dark ? .light : .dark)
        } label: {
            Image(systemName: dark ? "sun" : "moon")
                .font(.system(size: 20))
                .foregroundStyle(dark ? TodayStyle.color(0x69adff) : blue)
                .frame(width: 40, height: 40)
                .background(.white.opacity(dark ? 0.05 : 0.48), in: Circle())
        }
        .accessibilityLabel(dark ? "切换为浅色模式" : "切换为深色模式")
    }

    private func submit() {
        guard !state.isLoginSubmitting else { return }
        focusedField = nil
        Task { await state.login(username: username, password: password) }
    }
}
