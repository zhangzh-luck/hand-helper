import SwiftUI

@MainActor
struct AnalysisView: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        GradeImportView(state: state)
                    } label: {
                        Label(state.visibleGradeImport == nil ? "导入成绩文件" : "查看成绩导入状态",
                              systemImage: "doc.badge.plus")
                    }
                } footer: {
                    Text("支持教务系统导出的 .xls、.html 或 .htm 文件。本阶段只解析并预览，不会写入成绩。")
                }
            }
            .navigationTitle("分析")
        }
    }
}
