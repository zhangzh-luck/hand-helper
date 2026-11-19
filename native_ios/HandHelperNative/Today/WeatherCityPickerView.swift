import SwiftUI

@MainActor
struct WeatherCityPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: WeatherViewModel
    @State private var query = ""
    @State private var results: [WeatherCity] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("搜索城市", text: $query)
                        .autocorrectionDisabled()
                    if loading { ProgressView("正在搜索") }
                    if let error { Text(error).foregroundStyle(.secondary) }
                    ForEach(results) { city in
                        Button {
                            model.choose(city)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(city.name)
                                if !city.detail.isEmpty { Text(city.detail).font(.caption).foregroundStyle(.secondary) }
                                Text("城市编号 \(city.id)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("搜索结果包含地区和国家，方便区分同名城市。")
                }
                Section {
                    Button("重新读取天气") { model.retry(); dismiss() }
                } footer: {
                    Text("自动识别通过 IPwhois 根据公网 IP 估计城市，其服务可能记录 IP；应用不保存 IP。天气由 Open-Meteo 提供，城市数据来自 GeoNames。")
                }
            }
            .navigationTitle("选择城市")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .task(id: query) {
                let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
                results = []; error = nil
                guard term.count >= 2 else { loading = false; return }
                loading = true
                do {
                    try await Task.sleep(nanoseconds: 350_000_000)
                    let found = try await model.search(term)
                    guard !Task.isCancelled else { return }
                    results = found
                    if found.isEmpty { error = "没有找到城市，请尝试其他名称。" }
                    loading = false
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = "城市搜索暂不可用，请检查网络。"; loading = false
                }
            }
        }
    }
}
