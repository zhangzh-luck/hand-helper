import SwiftUI

@MainActor
struct LifeHomeSettingsView: View {
    @ObservedObject private var state: AppState
    @ObservedObject private var weather: WeatherViewModel
    @State private var choosingCity = false

    init(state: AppState) {
        self.state = state
        _weather = ObservedObject(wrappedValue: state.weatherModel)
    }

    private func preference(_ keyPath: WritableKeyPath<LifeHomePreferences, Bool>) -> Binding<Bool> {
        Binding(get: { state.lifeHomePreferences[keyPath: keyPath] },
                set: { state.setLifeHomePreference(keyPath, value: $0) })
    }

    private var cityDescription: String {
        if let city = weather.selectedManualCity { return "手动 · \(city.name)" }
        if let city = weather.cache?.city { return "自动 · \(city.name)" }
        return weather.loading ? "自动识别中" : "自动识别"
    }

    var body: some View {
        List {
            Section {
                Toggle("显示天气", isOn: preference(\.showWeather))
                Button { choosingCity = true } label: {
                    HStack {
                        Text("天气城市")
                        Spacer()
                        Text(cityDescription).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                if weather.selectedManualCity != nil {
                    Button("恢复自动识别") { weather.restoreAutomatic() }
                }
            } header: { Text("天气") } footer: {
                Text("自动识别根据公网 IP 估计城市，不使用设备定位。关闭天气后不会自动请求天气。")
            }
            Section("模块展示") {
                Toggle("显示财务摘要", isOn: preference(\.showFinance))
                Toggle("显示快捷操作", isOn: preference(\.showShortcuts))
                Toggle("显示订阅摘要", isOn: preference(\.showSubscriptions))
            }
            Section("隐私") {
                Toggle("隐藏财务金额", isOn: preference(\.hideFinancialAmounts))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("生活首页")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $choosingCity) { WeatherCityPickerView(model: weather) }
    }
}
