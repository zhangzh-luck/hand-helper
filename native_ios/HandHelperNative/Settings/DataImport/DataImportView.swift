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
                    SettingsNavigationRow(title: "导入课表", symbol: "calendar.badge.plus",
                                          color: Color(uiColor: .systemBlue))
                }
                .listRowInsets(SettingsNavigationRow.rowInsets)
                NavigationLink {
                    GradeImportView(state: state)
                } label: {
                    SettingsNavigationRow(title: "导入成绩", symbol: "doc.badge.plus",
                                          color: Color(uiColor: .systemTeal))
                }
                .listRowInsets(SettingsNavigationRow.rowInsets)
            } footer: {
                Text("课表导入会更新今日课程；成绩导入目前仅解析并预览，不会写入成绩。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("数据与导入")
        .navigationBarTitleDisplayMode(.inline)
    }
}
