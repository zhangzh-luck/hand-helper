import SwiftUI

@MainActor
struct WallpaperManagementView: View {
    @ObservedObject var state: AppState
    @Environment(\.settingsNavigator) private var navigator

    var body: some View {
        Form {
            Section {
                SettingsNavigationButton {
                    navigator?.push(title: "今日页壁纸") {
                        WallpaperSettingsView(state: state, kind: .today)
                    }
                } label: {
                    SettingsNavigationRow(title: "今日页壁纸", symbol: "house",
                                          color: Color(uiColor: .systemBlue))
                }
                .listRowInsets(SettingsNavigationRow.rowInsets)
                SettingsNavigationButton {
                    navigator?.push(title: "课程表壁纸") {
                        WallpaperSettingsView(state: state, kind: .timetable)
                    }
                } label: {
                    SettingsNavigationRow(title: "课程表壁纸", symbol: "calendar",
                                          color: Color(uiColor: .systemPurple))
                }
                .listRowInsets(SettingsNavigationRow.rowInsets)
                SettingsNavigationButton {
                    navigator?.push(title: "分析页壁纸") {
                        WallpaperSettingsView(state: state, kind: .analysis)
                    }
                } label: {
                    SettingsNavigationRow(title: "分析页壁纸", symbol: "chart.bar",
                                          color: Color(uiColor: .systemTeal))
                }
                .listRowInsets(SettingsNavigationRow.rowInsets)
            } footer: {
                Text("三张壁纸分别保存在此设备，不会上传服务器。")
            }
        }
        .navigationTitle("壁纸")
        .navigationBarTitleDisplayMode(.inline)
    }
}
