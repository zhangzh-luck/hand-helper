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
                NavigationLink {
                    GradeImportView(state: state)
                } label: {
                    Label("导入成绩", systemImage: "doc.badge.plus")
                }
            } footer: {
                Text("课表导入会更新今日课程；成绩导入目前仅解析并预览，不会写入成绩。")
            }
        }
        .navigationTitle("数据与导入")
        .navigationBarTitleDisplayMode(.inline)
    }
}
