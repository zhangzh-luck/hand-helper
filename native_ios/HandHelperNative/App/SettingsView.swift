import SwiftUI
import UIKit

@MainActor
struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var confirmLogout = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ProfileView(state: state, revision: state.authenticationRevision,
                                    presentation: .navigation)
                    } label: {
                        HStack(spacing: 14) {
                            profileAvatar
                            VStack(alignment: .leading, spacing: 3) {
                                Text(state.currentProfile.resolvedDisplayName)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("个人资料")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                    }
                } footer: {
                    Text("头像和显示名称仅保存在此设备。")
                }

                Section("外观") {
                    NavigationLink {
                        AppearanceSettingsView(state: state)
                    } label: {
                        LabeledContent {
                            Text(state.appearance.settingsTitle)
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("显示模式", systemImage: "circle.lefthalf.filled")
                        }
                    }
                }

                Section("关于") {
                    NavigationLink {
                        AboutHandHelperView()
                    } label: {
                        Label("关于航的助手", systemImage: "info.circle")
                    }
                }

                Section {
                    Button(role: .destructive) { confirmLogout = true } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("设置")
            .confirmationDialog("退出当前账号？", isPresented: $confirmLogout) {
                Button("退出登录", role: .destructive) {
                    Task { await state.logout() }
                }
            } message: {
                Text("本机保存的个人资料会保留，重新验证同一账号后可继续使用。")
            }
        }
    }

    private var profileAvatar: some View {
        Group {
            if let data = state.currentProfile.avatarData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(state.currentProfile.resolvedDisplayName == "航的助手"
                     ? "航" : String(state.currentProfile.resolvedDisplayName.suffix(1)))
                    .font(.title2.bold())
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 54, height: 54)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private extension AppearanceMode {
    var settingsTitle: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

@MainActor
private struct AppearanceSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                Picker("显示模式", selection: Binding(
                    get: { state.appearance },
                    set: { state.setAppearance($0) }
                )) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.settingsTitle).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } footer: {
                Text("跟随系统会使用设备当前的外观设置。")
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutHandHelperView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("应用名称", value: "航的助手 / Hand Helper")
                LabeledContent("客户端", value: "原生 iOS")
                LabeledContent("版本", value: version)
                LabeledContent("Build", value: build)
            }
        }
        .navigationTitle("关于航的助手")
        .navigationBarTitleDisplayMode(.inline)
    }
}
