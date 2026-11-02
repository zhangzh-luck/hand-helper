import SwiftUI

struct ManualCourseDraft {
    var name = ""
    var weeks: Set<Int>
    var weekday: Int
    var startPeriod: Int
    var endPeriod: Int
    var room = ""
    var teacher = ""

    init(cell: TimetableEmptyCellSelection) {
        weeks = [cell.week]
        weekday = cell.weekday
        startPeriod = cell.periodNumber
        endPeriod = cell.periodNumber
    }

    func validationMessage(availablePeriods: Set<Int>) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入课程名称。" }
        if weeks.isEmpty || !weeks.allSatisfy({ (1...20).contains($0) }) {
            return "请至少选择一个第 1 至 20 周的教学周。"
        }
        if !(1...7).contains(weekday) || !availablePeriods.contains(startPeriod) ||
            !availablePeriods.contains(endPeriod) || endPeriod < startPeriod {
            return "请选择有效的星期和起止节次。"
        }
        return nil
    }
}

struct ManualCourseEditorRoute: Identifiable {
    let id = UUID()
    let cell: TimetableEmptyCellSelection
    let operationID: UUID
    let tappedAt: TimeInterval
}

@MainActor
struct ManualCourseEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ManualCourseDraft
    @State private var pending = false
    @State private var errorMessage: String?
    let periods: [PeriodInfo]
    let save: (ManualCourseDraft) throws -> Void

    init(cell: TimetableEmptyCellSelection, periods: [PeriodInfo],
         save: @escaping (ManualCourseDraft) throws -> Void) {
        _draft = State(initialValue: ManualCourseDraft(cell: cell))
        self.periods = periods
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("课程") {
                    TextField("课程名称", text: $draft.name)
                        .accessibilityLabel("课程名称，必填")
                    NavigationLink {
                        ManualCourseWeekPicker(weeks: $draft.weeks)
                    } label: {
                        LabeledContent("上课周次", value: weekSummary)
                    }
                    Picker("星期", selection: $draft.weekday) {
                        ForEach(1...7, id: \.self) { day in
                            Text(["周一", "周二", "周三", "周四", "周五", "周六", "周日"][day - 1]).tag(day)
                        }
                    }
                    Picker("开始节次", selection: $draft.startPeriod) {
                        ForEach(periods, id: \.periodNumber) { period in
                            Text("第 \(period.periodNumber) 节 · \(TimetablePeriodLabel.safeTime(period.startTime))")
                                .tag(period.periodNumber)
                        }
                    }
                    Picker("结束节次", selection: $draft.endPeriod) {
                        ForEach(periods, id: \.periodNumber) { period in
                            Text("第 \(period.periodNumber) 节 · \(TimetablePeriodLabel.safeTime(period.endTime))")
                                .tag(period.periodNumber)
                        }
                    }
                }
                Section("补充信息") {
                    TextField("教室（选填）", text: $draft.room)
                    TextField("任课教师（选填）", text: $draft.teacher)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("添加课程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(pending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard !pending else { return }
                        if let message = draft.validationMessage(
                            availablePeriods: Set(periods.map(\.periodNumber))) {
                            errorMessage = message
                            return
                        }
                        pending = true
                        errorMessage = nil
                        defer { pending = false }
                        do {
                            try save(draft)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    } label: {
                        if pending { ProgressView() } else { Text("保存") }
                    }
                    .disabled(pending)
                }
            }
        }
        .interactiveDismissDisabled(pending)
    }

    private var weekSummary: String {
        let sorted = draft.weeks.sorted()
        return sorted.isEmpty ? "请选择" : "第 \(sorted.map(String.init).joined(separator: "、")) 周"
    }
}

private struct ManualCourseWeekPicker: View {
    @Binding var weeks: Set<Int>

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("全选") { weeks = Set(1...20) }
                    Spacer()
                    Button("单周") { weeks = Set(stride(from: 1, through: 19, by: 2)) }
                    Spacer()
                    Button("双周") { weeks = Set(stride(from: 2, through: 20, by: 2)) }
                    Spacer()
                    Button("清空") { weeks = [] }
                }
                .buttonStyle(.borderless)
            }
            Section("教学周 · 已选 \(weeks.count) 周") {
                ForEach(1...20, id: \.self) { week in
                    Button {
                        if weeks.contains(week) { weeks.remove(week) }
                        else { weeks.insert(week) }
                    } label: {
                        HStack {
                            Text("第 \(week) 周")
                            Spacer()
                            if weeks.contains(week) { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(weeks.contains(week) ? .isSelected : [])
                }
            }
        }
        .navigationTitle("上课周次")
    }
}
