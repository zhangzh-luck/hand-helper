import SwiftUI

private enum ManualCourseEditorFormHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum ManualCourseEditorLayout {
    private static let fixedChromeHeight: CGFloat = 132

    static func maximumFormHeight(in availableHeight: CGFloat) -> CGFloat {
        max(120, availableHeight - fixedChromeHeight)
    }

    static func formViewportHeight(contentHeight: CGFloat?, maximum: CGFloat) -> CGFloat {
        min(contentHeight ?? maximum, maximum)
    }
}

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

typealias ManualCourseEditorSaveAction = (ManualCourseDraft) throws -> Void

struct ManualCourseEditorPresentationRoute: Identifiable {
    let id = UUID()
    let draft: ManualCourseDraft
    let periods: [PeriodInfo]
    let isEditing: Bool
    let onSave: ManualCourseEditorSaveAction
    let onFinish: () -> Void
}

@MainActor
final class ManualCourseEditorCoordinator: ObservableObject {
    @Published private(set) var route: ManualCourseEditorPresentationRoute?
    @Published private(set) var isVisible = false
    private var isDismissing = false

    var isPresenting: Bool { route != nil }

    func present(draft: ManualCourseDraft, periods: [PeriodInfo], isEditing: Bool,
                 onSave: @escaping ManualCourseEditorSaveAction,
                 onFinish: @escaping () -> Void) {
        guard route == nil else { return }
        route = ManualCourseEditorPresentationRoute(draft: draft, periods: periods,
                                                    isEditing: isEditing, onSave: onSave,
                                                    onFinish: onFinish)
        isVisible = false
        isDismissing = false
    }

    func show(id: UUID) {
        guard route?.id == id, !isDismissing, !isVisible else { return }
        isVisible = true
    }

    func prepareDismissal(id: UUID) -> Bool {
        guard route?.id == id, isVisible, !isDismissing else { return false }
        isDismissing = true
        return true
    }

    func hide(id: UUID) {
        guard route?.id == id, isDismissing, isVisible else { return }
        isVisible = false
    }

    func finishDismissal(id: UUID) {
        guard let route, route.id == id, isDismissing, !isVisible else { return }
        self.route = nil
        isDismissing = false
        route.onFinish()
    }

    func clear() {
        guard route != nil || isVisible || isDismissing else { return }
        route = nil
        isVisible = false
        isDismissing = false
    }
}

struct ManualCourseEditorOverlay: View {
    @ObservedObject var coordinator: ManualCourseEditorCoordinator
    let reduceMotion: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if let route = coordinator.route {
            GeometryReader { geometry in
                ZStack {
                    Color.black
                        .opacity(reduceTransparency ? 0.56 : 0.34)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {}
                        .opacity(coordinator.isVisible ? 1 : 0)

                    ManualCourseEditorView(route: route,
                                           maximumFormHeight: ManualCourseEditorLayout.maximumFormHeight(
                                            in: geometry.size.height - 48),
                                           onClose: { dismiss(routeID: route.id) })
                        .frame(maxWidth: 520)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                        .opacity(coordinator.isVisible ? 1 : 0)
                        .scaleEffect(reduceMotion ? 1 : (coordinator.isVisible ? 1 : 0.96))
                        .accessibilityAddTraits(.isModal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear { withAnimation(animation) { coordinator.show(id: route.id) } }
        }
    }

    private var animation: Animation {
        reduceMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.22)
    }

    private func dismiss(routeID: UUID) {
        guard coordinator.prepareDismissal(id: routeID) else { return }
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            coordinator.hide(id: routeID)
        } completion: {
            coordinator.finishDismissal(id: routeID)
        }
    }
}

@MainActor
struct ManualCourseEditorView: View {
    @State private var draft: ManualCourseDraft
    @State private var showingWeekPicker = false
    @State private var pending = false
    @State private var errorMessage: String?
    @State private var measuredFormHeight: CGFloat?
    let route: ManualCourseEditorPresentationRoute
    let maximumFormHeight: CGFloat
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AccessibilityFocusState private var titleFocused: Bool

    init(route: ManualCourseEditorPresentationRoute, maximumFormHeight: CGFloat,
         onClose: @escaping () -> Void) {
        _draft = State(initialValue: route.draft)
        self.route = route
        self.maximumFormHeight = maximumFormHeight
        self.onClose = onClose
    }

    var body: some View {
        editorCard
            .overlay { weekPickerOverlay }
        .onAppear { titleFocused = true }
    }

    private var weekSummary: String {
        let sorted = draft.weeks.sorted()
        return sorted.isEmpty ? "请选择" : "第 \(sorted.map(String.init).joined(separator: "、")) 周"
    }

    private var editorCard: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                formContent
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ManualCourseEditorFormHeightKey.self,
                                                   value: proxy.size.height)
                        }
                    }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .frame(height: ManualCourseEditorLayout.formViewportHeight(
                contentHeight: measuredFormHeight, maximum: maximumFormHeight), alignment: .top)
            Divider()
            saveAction
        }
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .onPreferenceChange(ManualCourseEditorFormHeightKey.self) { height in
            guard height > 0,
                  measuredFormHeight.map({ abs($0 - height) > 0.5 }) ?? true else { return }
            measuredFormHeight = height
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(route.isEditing ? "编辑课程" : "添加课程")
                .font(.headline)
                .accessibilityFocused($titleFocused)
            Spacer(minLength: 0)
            GlassCloseButton(accessibilityLabel: "关闭", diameter: 36, onDarkBackground: false,
                             action: onClose)
                .frame(width: 44, height: 44)
                .disabled(pending)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(minHeight: 56)
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            courseFieldsSurface
            supplementaryFieldsSurface
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("manualCourseEditorError")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var courseFields: some View {
        VStack(spacing: 0) {
            HStack {
                Text("课程名称")
                TextField("必填", text: $draft.name)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("课程名称，必填")
            }
            .frame(minHeight: 57)
            Divider()
            Button {
                showingWeekPicker = true
            } label: {
                LabeledContent("上课周次", value: weekSummary)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .frame(minHeight: 57)
            Divider()
            HStack {
                Text("星期")
                Spacer(minLength: 12)
                Picker("星期", selection: $draft.weekday) {
                    ForEach(1...7, id: \.self) { day in
                        Text(["周一", "周二", "周三", "周四", "周五", "周六", "周日"][day - 1]).tag(day)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .frame(minHeight: 57)
            Divider()
            HStack {
                Text("开始节次")
                Spacer(minLength: 12)
                Picker("开始节次", selection: $draft.startPeriod) {
                    ForEach(route.periods, id: \.periodNumber) { period in
                        Text("第 \(period.periodNumber) 节 · \(TimetablePeriodLabel.safeTime(period.startTime))")
                            .tag(period.periodNumber)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .frame(minHeight: 57)
            Divider()
            HStack {
                Text("结束节次")
                Spacer(minLength: 12)
                Picker("结束节次", selection: $draft.endPeriod) {
                    ForEach(route.periods, id: \.periodNumber) { period in
                        Text("第 \(period.periodNumber) 节 · \(TimetablePeriodLabel.safeTime(period.endTime))")
                            .tag(period.periodNumber)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .frame(minHeight: 57)
        }
    }

    private var supplementaryFields: some View {
        VStack(spacing: 0) {
            HStack {
                Text("教室")
                TextField("选填", text: $draft.room)
                    .multilineTextAlignment(.trailing)
            }
            .frame(minHeight: 57)
            Divider()
            HStack {
                Text("任课教师")
                TextField("选填", text: $draft.teacher)
                    .multilineTextAlignment(.trailing)
            }
            .frame(minHeight: 57)
        }
    }

    @ViewBuilder
    private var courseFieldsSurface: some View { glassSurface(courseFields) }

    @ViewBuilder
    private var supplementaryFieldsSurface: some View { glassSurface(supplementaryFields) }

    @ViewBuilder
    private func glassSurface<Content: View>(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(iOS 26.0, *), !reduceTransparency, colorSchemeContrast != .increased {
            content.padding(.horizontal, 15).glassEffect(.regular, in: shape)
        } else if reduceTransparency || colorSchemeContrast == .increased {
            content.padding(.horizontal, 15)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
        } else {
            content.padding(.horizontal, 15).background(.regularMaterial, in: shape)
        }
    }

    private var saveAction: some View {
        let button = Button(action: save) {
            if pending { ProgressView().tint(.white) }
            else { Text(route.isEditing ? "保存更改" : "保存课程") }
        }
        .font(.system(size: 15, weight: .bold))
        .frame(maxWidth: .infinity, minHeight: 52)
        .tint(TodayStyle.color(0x2563eb))
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .disabled(pending || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("manualCourseEditorSave")

        return Group {
            if #available(iOS 26.0, *), !reduceTransparency, colorSchemeContrast != .increased {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.borderedProminent)
            }
        }
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .frame(maxWidth: .infinity, minHeight: 52)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var weekPickerOverlay: some View {
        if showingWeekPicker {
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(reduceTransparency ? 0.48 : 0.28)
                        .contentShape(Rectangle())
                        .onTapGesture {}
                    ManualCourseWeekPicker(weeks: $draft.weeks,
                                           maximumGridHeight: ManualCourseWeekPickerLayout.maximumGridHeight(
                                            in: geometry.size.height - 32),
                                           onCancel: dismissWeekPicker,
                                           onComplete: dismissWeekPicker)
                        .frame(maxWidth: 460)
                        .padding(16)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                        .accessibilityAddTraits(.isModal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func dismissWeekPicker() {
        withAnimation(reduceMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.18)) {
            showingWeekPicker = false
        }
    }

    private func save() {
        guard !pending else { return }
        if let message = draft.validationMessage(availablePeriods: Set(route.periods.map(\.periodNumber))) {
            errorMessage = message
            return
        }
        pending = true
        errorMessage = nil
        defer { pending = false }
        do {
            try route.onSave(draft)
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
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

private enum ManualCourseWeekPickerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum ManualCourseWeekPickerControlLayout {
    static let compactVisualHeight: CGFloat = 38
    static let minimumTouchHeight: CGFloat = 44
    static let completeHeight: CGFloat = 52
    static let controlSpacing: CGFloat = 8
}

enum ManualCourseWeekPickerLayout {
    private static let fixedChromeHeight: CGFloat = 132

    static func maximumGridHeight(in availableHeight: CGFloat) -> CGFloat {
        max(140, availableHeight - fixedChromeHeight)
    }

    static func gridViewportHeight(contentHeight: CGFloat?, maximum: CGFloat) -> CGFloat {
        min(contentHeight ?? maximum, maximum)
    }
}

private struct ManualCourseWeekPicker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding private var weeks: Set<Int>
    @State private var draft: ManualCourseWeekDraft
    @State private var measuredGridHeight: CGFloat?
    let maximumGridHeight: CGFloat
    let onCancel: () -> Void
    let onComplete: () -> Void

    init(weeks: Binding<Set<Int>>, maximumGridHeight: CGFloat,
         onCancel: @escaping () -> Void,
         onComplete: @escaping () -> Void) {
        _weeks = weeks
        _draft = State(initialValue: ManualCourseWeekDraft(weeks: weeks.wrappedValue))
        self.maximumGridHeight = maximumGridHeight
        self.onCancel = onCancel
        self.onComplete = onComplete
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("上课周次").font(.headline)
                Spacer()
                secondaryGlassButton("取消", action: onCancel)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 56)
            Divider()
            ScrollView {
                gridContent
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ManualCourseWeekPickerHeightKey.self,
                                                   value: proxy.size.height)
                        }
                    }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .frame(height: ManualCourseWeekPickerLayout.gridViewportHeight(
                contentHeight: measuredGridHeight, maximum: maximumGridHeight), alignment: .top)
            Divider()
            completeAction
        }
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .onPreferenceChange(ManualCourseWeekPickerHeightKey.self) { height in
            guard height > 0,
                  measuredGridHeight.map({ abs($0 - height) > 0.5 }) ?? true else { return }
            measuredGridHeight = height
        }
        .accessibilityElement(children: .contain)
    }

    private var gridContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                    bulkButtons
                }
            } else {
                HStack(spacing: ManualCourseWeekPickerControlLayout.controlSpacing) { bulkButtons }
            }
            Text("教学周 · 已选 \(draft.selection.count) / 20 周")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(1...20, id: \.self) { week in
                    weekButton(week)
                }
            }
        }
        .padding(18)
    }

    @ViewBuilder
    private var bulkButtons: some View {
        bulkButton("全选", selection: ManualCourseWeekChoices.all)
        bulkButton("单周", selection: ManualCourseWeekChoices.odd)
        bulkButton("双周", selection: ManualCourseWeekChoices.even)
        bulkButton("清空", selection: [])
    }

    private func bulkButton(_ title: String, selection newSelection: Set<Int>) -> some View {
        secondaryGlassButton(title) { updateSelection(newSelection) }
    }

    @ViewBuilder
    private func secondaryGlassButton(_ title: String, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 10)
                .frame(minHeight: ManualCourseWeekPickerControlLayout.compactVisualHeight)
        }
        if #available(iOS 26.0, *), !reduceTransparency, colorSchemeContrast != .increased {
            button.buttonStyle(.glass)
                .frame(minWidth: 44, minHeight: ManualCourseWeekPickerControlLayout.minimumTouchHeight)
        } else {
            button.buttonStyle(.bordered)
                .frame(minWidth: 44, minHeight: ManualCourseWeekPickerControlLayout.minimumTouchHeight)
        }
    }

    private var completeAction: some View {
        let button = Button {
            guard let completed = draft.completedSelection else { return }
            weeks = completed
            onComplete()
        } label: {
            HStack {
                Spacer(minLength: 0)
                Text("完成")
                    .font(.system(size: 15, weight: .bold))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: ManualCourseWeekPickerControlLayout.completeHeight)
        }
        .tint(TodayStyle.color(0x2563eb))
        .disabled(draft.completedSelection == nil)

        return Group {
            if #available(iOS 26.0, *), !reduceTransparency, colorSchemeContrast != .increased {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.borderedProminent)
            }
        }
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .frame(maxWidth: .infinity, minHeight: ManualCourseWeekPickerControlLayout.completeHeight)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
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
