import SwiftUI

@MainActor
struct PersonalizationView: View {
    @ObservedObject var state: AppState

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
                                .font(.body)
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
                NavigationLink {
                    WallpaperManagementView(state: state)
                } label: {
                    Label("壁纸", systemImage: "photo")
                }
            } header: {
                Text("壁纸")
            } footer: {
                Text("今日页和课程表壁纸分别保存在此设备。")
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
