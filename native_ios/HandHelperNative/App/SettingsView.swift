import SwiftUI
import UIKit

@MainActor
struct SettingsView: View {
    @ObservedObject var state: AppState
    @Environment(\.settingsNavigator) private var navigator
    @StateObject private var avatarImageCache = SettingsAvatarImageCache()

    var body: some View {
        List {
                Section {
                    SettingsNavigationButton {
                        navigator?.push(title: "账户设置") {
                            ProfileView(state: state, revision: state.authenticationRevision,
                                        presentation: .navigation)
                        }
                    } label: {
                        HStack(spacing: 14) {
                            profileAvatar
                            VStack(alignment: .leading, spacing: 3) {
                                Text(state.currentProfile.resolvedDisplayName)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("账户设置")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("账户")
                } footer: {
                    Text("头像和显示名称仅保存在此设备。")
                }

                Section {
                    SettingsNavigationButton {
                        navigator?.push(title: "时间设置") {
                            AcademicTimeView(state: state)
                        }
                    } label: {
                        SettingsNavigationRow(title: "时间设置", symbol: "clock",
                                              color: Color(uiColor: .systemBlue))
                    }
                    .listRowInsets(SettingsNavigationRow.rowInsets)
                    SettingsNavigationButton {
                        navigator?.push(title: "个性化") {
                            PersonalizationView(state: state)
                        }
                    } label: {
                        SettingsNavigationRow(title: "个性化", symbol: "paintpalette",
                                              color: Color(uiColor: .systemPurple))
                    }
                    .listRowInsets(SettingsNavigationRow.rowInsets)
                } header: {
                    Text("偏好设置")
                }

                Section {
                    SettingsNavigationButton {
                        navigator?.push(title: "数据与导入") {
                            DataImportView(state: state)
                        }
                    } label: {
                        SettingsNavigationRow(title: "数据与导入", symbol: "square.and.arrow.down",
                                              color: Color(uiColor: .systemTeal))
                    }
                    .listRowInsets(SettingsNavigationRow.rowInsets)
                    SettingsNavigationButton {
                        navigator?.push(title: "AI 模型配置") {
                            AIModelSettingsView(state: state)
                        }
                    } label: {
                        SettingsNavigationRow(title: "AI 模型配置", symbol: "sparkles",
                                              color: Color(uiColor: .systemIndigo))
                    }
                    .listRowInsets(SettingsNavigationRow.rowInsets)
                    SettingsNavigationButton {
                        navigator?.push(title: "关于航的助手") {
                            AboutHandHelperView()
                        }
                    } label: {
                        Text("关于航的助手")
                            .frame(minHeight: 56)
                    }
                    .listRowInsets(SettingsNavigationRow.rowInsets)
                } header: {
                    Text("数据与助手")
                }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .task { avatarImageCache.update(data: state.currentProfile.avatarData) }
        .onChange(of: state.currentProfile.avatarData) { _, data in avatarImageCache.update(data: data) }
    }

    private var profileAvatar: some View {
        Group {
            if let image = avatarImageCache.image {
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

/// Decodes only when avatar bytes change; rendering the Settings row never decodes image data.
@MainActor
final class SettingsAvatarImageCache: ObservableObject {
    @Published private(set) var image: UIImage?
    private var sourceData: Data?

    func update(data: Data?) {
        guard data != sourceData else { return }
        sourceData = data
        image = data.flatMap { UIImage(data: $0) }
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
