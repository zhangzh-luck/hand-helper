import SwiftUI

@MainActor
struct DataImportView: View {
    @ObservedObject var state: AppState

    var body: some View {
        List {
            Section {
                NavigationLink {
                    TimetableImportView(state: state)
                } label: {
                    Label("导入课表", systemImage: "calendar.badge.plus")
                }
            } footer: {
                Text("选择教务系统打印导出的 .xls 文件。导入结果会更新今日课程。")
            }
        }
        .navigationTitle("数据与导入")
        .navigationBarTitleDisplayMode(.inline)
    }
}
