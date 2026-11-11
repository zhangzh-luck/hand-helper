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
                        SettingsNavigationRow(title: "关于航的助手", assetName: "BrandMark")
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
                HStack(spacing: 16) {
                    Image("BrandMark")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(.white.opacity(0.7), lineWidth: 1)
                        }
                        .shadow(color: Color.accentColor.opacity(0.24), radius: 10, y: 5)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("航的助手")
                            .font(.title3.weight(.bold))
                        Text("Hand Helper")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("版本 \(version)（Build \(build)）")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)
                .background(Color.accentColor.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            Section("应用说明") {
                Text("为个人使用场景设计的课程表与成绩分析助手。课程和成绩通过你主动导入的文件获取。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                AboutInfoRow(title: "使用范围", detail: "仅供本人使用", symbol: "person.crop.circle")
                AboutInfoRow(title: "数据处理", detail: "主动导入文件，由已登录后端解析并保存", symbol: "arrow.triangle.2.circlepath")
            }

            Section("帮助中心") {
                DisclosureGroup("导入打印课表") {
                    Text("在教务系统保存 .xls 打印课表，进入“数据与导入”选择文件；首次导入后设置学期第一周周一。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                DisclosureGroup("导入成绩分析") {
                    Text("选择 .xls 或 HTML 成绩文件，检查预览并确认导入。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                DisclosureGroup("使用 AI 成绩分析") {
                    Text("先配置 HTTPS 模型服务、模型和 API Key，再到分析页主动生成分析建议。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            }

            Section("隐私与安全") {
                AboutInfoRow(title: "本地资料", detail: "头像、显示名称和壁纸保存在此设备。", symbol: "iphone")
                AboutInfoRow(title: "导入文件", detail: "原始课表和成绩文件仅用于当次解析，不作为文件持久保存。", symbol: "doc.badge.arrow.up")
                AboutInfoRow(title: "后端服务", detail: "确认导入后，解析后的课程和成绩保存在已登录后端，用于课表和成绩功能。", symbol: "server.rack")
                AboutInfoRow(title: "第三方 AI", detail: "仅在你主动生成分析时，当前学期必要的课程和成绩信息会发送至已配置的模型服务。", symbol: "sparkles")
                AboutInfoRow(title: "模型密钥", detail: "API Key 由后端安全保存，客户端不会通过读取配置回显明文。", symbol: "key")
            }

            Section("版本信息") {
                LabeledContent("客户端", value: "原生 iOS")
                LabeledContent("版本", value: version)
                LabeledContent("Build", value: build)
            }
        }
        .navigationTitle("关于航的助手")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutInfoRow: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 20)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
