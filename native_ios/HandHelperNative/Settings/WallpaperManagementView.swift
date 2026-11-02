import SwiftUI

@MainActor
struct WallpaperManagementView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    WallpaperSettingsView(state: state, kind: .today)
                } label: {
                    Label("今日页壁纸", systemImage: "house")
                }
                NavigationLink {
                    WallpaperSettingsView(state: state, kind: .timetable)
                } label: {
                    Label("课程表壁纸", systemImage: "calendar")
                }
                NavigationLink {
                    WallpaperSettingsView(state: state, kind: .analysis)
                } label: {
                    Label("分析页壁纸", systemImage: "chart.bar")
                }
            } footer: {
                Text("三张壁纸分别保存在此设备，不会上传服务器。")
            }
        }
        .navigationTitle("壁纸")
        .navigationBarTitleDisplayMode(.inline)
    }
}
