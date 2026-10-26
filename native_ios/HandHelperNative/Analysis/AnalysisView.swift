import SwiftUI

@MainActor
struct AnalysisView: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("成绩展示与分析将在后续阶段实现。")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("分析")
        }
    }
}
