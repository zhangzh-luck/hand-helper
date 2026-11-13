import ActivityKit
import SwiftUI

@MainActor
struct PersonalizationView: View {
    @ObservedObject var state: AppState
    @Environment(\.settingsNavigator) private var navigator

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("显示模式")
                        Spacer()
                        Text(state.appearance.settingsTitle)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    Picker("显示模式", selection: Binding(
                        get: { state.appearance },
                        set: { state.setAppearance($0) }
                    )) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Label(mode.settingsTitle, systemImage: mode.settingsSymbol)
                                .labelStyle(.iconOnly)
                                .font(.system(size: 20, weight: .semibold))
                                .symbolRenderingMode(.monochrome)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            } header: {
                Text("外观")
            } footer: {
                Text("跟随系统会使用设备当前的外观设置。")
            }

            Section {
                SettingsNavigationButton {
                    navigator?.push(title: "壁纸") {
                        WallpaperManagementView(state: state)
                    }
                } label: {
                    SettingsNavigationRow(title: "壁纸", symbol: "photo",
                                          color: Color(uiColor: .systemPurple))
                }
                .listRowInsets(SettingsNavigationRow.rowInsets)
            } header: {
                Text("壁纸")
            }

            Section {
                Toggle("课程与安排实时活动", isOn: Binding(
                    get: { state.liveActivitiesEnabled },
                    set: { state.setLiveActivitiesEnabled($0) }
                ))
                if state.liveActivitiesEnabled && !ActivityAuthorizationInfo().areActivitiesEnabled {
                    Text("系统未允许实时活动，请在 iPhone 设置中检查本应用的实时活动权限。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                #if DEBUG
                SettingsNavigationButton {
                    navigator?.push(title: "实时活动诊断") {
                        LiveActivityDiagnosticView(state: state)
                    }
                } label: {
                    Text("实时活动诊断")
                }
                #endif
            } header: {
                Text("实时活动")
            } footer: {
                Text("开启后，正在进行的课程或安排可显示在锁屏和灵动岛，相关名称与地点可能被他人看到。")
            }
        }
        .navigationTitle("个性化")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension AppearanceMode {
    var settingsSymbol: String {
        switch self {
        case .system: "iphone"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var settingsTitle: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}
