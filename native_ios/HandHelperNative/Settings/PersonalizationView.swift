import SwiftUI

@MainActor
struct PersonalizationView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("外观") {
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

            Section("壁纸") {
                NavigationLink {
                    WallpaperSettingsView(state: state)
                } label: {
                    Label("今日页壁纸", systemImage: "photo")
                }
            } footer: {
                Text("壁纸仅保存在此设备，今日页只负责显示。")
            }
        }
        .navigationTitle("个性化")
        .navigationBarTitleDisplayMode(.inline)
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
