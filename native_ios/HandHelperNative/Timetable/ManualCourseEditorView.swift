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

    init(rule: ManualCourseRule) {
        name = rule.name
        weeks = Set(rule.weeks)
        weekday = rule.weekday
        startPeriod = rule.startPeriod
        endPeriod = rule.endPeriod
        room = rule.room ?? ""
        teacher = rule.teacher ?? ""
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

struct ManualCourseOperationRoute: Identifiable {
    let id = UUID()
    let rule: ManualCourseRule
    let request: TimetableManualCourseActionRequest
}

@MainActor
struct ManualCourseEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ManualCourseDraft
    @State private var pending = false
    @State private var errorMessage: String?
    let periods: [PeriodInfo]
    let save: (ManualCourseDraft) throws -> Void
    let isEditing: Bool

    init(cell: TimetableEmptyCellSelection, periods: [PeriodInfo],
         save: @escaping (ManualCourseDraft) throws -> Void) {
        _draft = State(initialValue: ManualCourseDraft(cell: cell))
        self.periods = periods
        self.save = save
        isEditing = false
    }

    init(rule: ManualCourseRule, periods: [PeriodInfo],
         save: @escaping (ManualCourseDraft) throws -> Void) {
        _draft = State(initialValue: ManualCourseDraft(rule: rule))
        self.periods = periods
        self.save = save
        isEditing = true
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
            .navigationTitle(isEditing ? "编辑课程" : "添加课程")
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

enum ManualCourseWeekChoices {
    static let all = Set(1...20)
    static let odd = Set(stride(from: 1, through: 19, by: 2))
    static let even = Set(stride(from: 2, through: 20, by: 2))

    static func toggling(_ week: Int, in selection: Set<Int>) -> Set<Int> {
        var result = selection
        if result.contains(week) { result.remove(week) }
        else { result.insert(week) }
        return result
    }
}

struct ManualCourseWeekDraft {
    private(set) var selection: Set<Int>

    init(weeks: Set<Int>) { selection = weeks }

    mutating func replace(with weeks: Set<Int>) { selection = weeks }

    // Only the explicit Complete action commits this temporary navigation state.
    var completedSelection: Set<Int>? { selection.isEmpty ? nil : selection }
}

private struct ManualCourseWeekPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding private var weeks: Set<Int>
    @State private var draft: ManualCourseWeekDraft

    init(weeks: Binding<Set<Int>>) {
        _weeks = weeks
        _draft = State(initialValue: ManualCourseWeekDraft(weeks: weeks.wrappedValue))
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        Form {
            Section {
                if dynamicTypeSize.isAccessibilitySize {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                        bulkButtons
                    }
                } else {
                    HStack(spacing: 8) { bulkButtons }
                }
            }
            Section("教学周 · 已选 \(draft.selection.count) / 20 周") {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(1...20, id: \.self) { week in
                        weekButton(week)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("上课周次")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    guard let completed = draft.completedSelection else { return }
                    weeks = completed
                    dismiss()
                }
                .disabled(draft.completedSelection == nil)
            }
        }
    }

    @ViewBuilder
    private var bulkButtons: some View {
        bulkButton("全选", selection: ManualCourseWeekChoices.all)
        bulkButton("单周", selection: ManualCourseWeekChoices.odd)
        bulkButton("双周", selection: ManualCourseWeekChoices.even)
        bulkButton("清空", selection: [])
    }

    private func bulkButton(_ title: String, selection newSelection: Set<Int>) -> some View {
        Button(title) { updateSelection(newSelection) }
            .font(.subheadline)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity)
            .buttonStyle(.bordered)
    }

    private func weekButton(_ week: Int) -> some View {
        let isSelected = draft.selection.contains(week)
        return Button {
            updateSelection(ManualCourseWeekChoices.toggling(week, in: draft.selection))
        } label: {
            RoundedRectangle(cornerRadius: 14)
                .fill(isSelected ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isSelected ? Color.accentColor : Color(uiColor: .separator), lineWidth: 1)
                }
                .overlay {
                    Text("\(week)")
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .minimumScaleFactor(0.8)
                }
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(week) 周")
        .accessibilityValue(isSelected ? "已选中" : "未选中")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func updateSelection(_ newSelection: Set<Int>) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            draft.replace(with: newSelection)
        }
    }
}
