import SwiftUI
import UIKit

@MainActor
struct SettingsView: View {
    @ObservedObject var state: AppState

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
                                Text("账户设置")
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

                Section {
                    NavigationLink {
                        AcademicTimeView(state: state)
                    } label: {
                        SettingsNavigationRow(title: "时间设置", symbol: "clock",
                                              color: Color(uiColor: .systemBlue))
                    }
                    NavigationLink {
                        DataImportView(state: state)
                    } label: {
                        SettingsNavigationRow(title: "数据与导入", symbol: "square.and.arrow.down",
                                              color: Color(uiColor: .systemTeal))
                    }
                    NavigationLink {
                        PersonalizationView(state: state)
                    } label: {
                        SettingsNavigationRow(title: "个性化", symbol: "paintpalette",
                                              color: Color(uiColor: .systemPurple))
                    }
                } footer: {
                    Text("调整教学时间、导入文件，以及管理外观和壁纸。")
                }

                Section("关于") {
                    NavigationLink {
                        AboutHandHelperView()
                    } label: {
                        SettingsNavigationRow(title: "关于航的助手", symbol: "info.circle",
                                              color: Color(uiColor: .systemGray))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
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

private struct SettingsNavigationRow: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
        }
        .frame(minHeight: 44)
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
