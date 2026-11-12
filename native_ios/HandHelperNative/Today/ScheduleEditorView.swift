import SwiftUI

typealias ScheduleEditorSaveAction = (Int?, String, Date, String, String?) throws -> Void

struct ScheduleEditorRoute: Identifiable {
    let id = UUID()
    let schedule: CustomSchedule?
    let now: Date
    let revision: Int
    let onSave: ScheduleEditorSaveAction
}

@MainActor
final class ScheduleEditorCoordinator: ObservableObject {
    @Published private(set) var route: ScheduleEditorRoute?
    @Published private(set) var isVisible = false
    private var isDismissing = false

    var isPresenting: Bool { route != nil }

    func present(schedule: CustomSchedule?, now: Date, revision: Int,
                 onSave: @escaping ScheduleEditorSaveAction) {
        guard route == nil else { return }
        route = ScheduleEditorRoute(schedule: schedule, now: now, revision: revision, onSave: onSave)
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
        guard route?.id == id, isDismissing, !isVisible else { return }
        route = nil
        isDismissing = false
    }

    func clear() {
        guard route != nil || isVisible || isDismissing else { return }
        route = nil
        isVisible = false
        isDismissing = false
    }
}

struct ScheduleEditorOverlay: View {
    @ObservedObject var coordinator: ScheduleEditorCoordinator
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

                    ScheduleEditorView(schedule: route.schedule, now: route.now,
                                       maximumFormHeight: ScheduleEditorLayout.maximumFormHeight(
                                        in: geometry.size.height - 48),
                                       onSave: route.onSave, onClose: { dismiss(routeID: route.id) })
                        .frame(maxWidth: 520)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                        .opacity(coordinator.isVisible ? 1 : 0)
                        .scaleEffect(reduceMotion ? 1 : (coordinator.isVisible ? 1 : 0.96))
                        .accessibilityAddTraits(.isModal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear { show(routeID: route.id) }
        }
    }

    private var animation: Animation {
        reduceMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.22)
    }

    private func show(routeID: UUID) {
        withAnimation(animation) { coordinator.show(id: routeID) }
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

struct ScheduleEditorView: View {
    let schedule: CustomSchedule?
    let now: Date
    let maximumFormHeight: CGFloat
    let onSave: ScheduleEditorSaveAction
    let onClose: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AccessibilityFocusState private var titleIsFocused: Bool
    @State private var title: String
    @State private var date: Date
    @State private var time: Date
    @State private var hasEndTime: Bool
    @State private var endTime: Date
    @State private var error: String?
    @State private var showDiscardConfirmation = false
    @State private var measuredFormHeight: CGFloat?

    init(schedule: CustomSchedule?, now: Date,
         maximumFormHeight: CGFloat,
         onSave: @escaping ScheduleEditorSaveAction, onClose: @escaping () -> Void) {
        self.schedule = schedule
        self.now = now
        self.maximumFormHeight = maximumFormHeight
        self.onSave = onSave
        self.onClose = onClose
        _title = State(initialValue: schedule?.title ?? "")
        let parsedDate: Date?
        if let raw = schedule?.date {
            let parts = raw.split(separator: "-").compactMap { Int($0) }
            parsedDate = parts.count == 3
                ? Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
                : nil
        } else {
            parsedDate = nil
        }
        let initialDate = parsedDate ?? now
        _date = State(initialValue: initialDate)
        _time = State(initialValue: CourseScheduleCalculator.dateTime(day: initialDate,
                            clock: schedule?.time ?? "09:00") ?? initialDate)
        _hasEndTime = State(initialValue: schedule?.endTime != nil)
        _endTime = State(initialValue: CourseScheduleCalculator.dateTime(day: initialDate,
                            clock: schedule?.endTime ?? "10:00") ?? initialDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                formContent
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ScheduleEditorFormHeightKey.self,
                                                   value: proxy.size.height)
                        }
                    }
            }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .frame(height: ScheduleEditorLayout.formViewportHeight(
                    contentHeight: measuredFormHeight, maximum: maximumFormHeight), alignment: .top)
            Divider()
            saveAction
        }
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .confirmationDialog("放弃未保存的更改？", isPresented: $showDiscardConfirmation) {
            Button("放弃更改", role: .destructive) { onClose() }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("当前填写的安排尚未保存。") }
        .onPreferenceChange(ScheduleEditorFormHeightKey.self) { height in
            guard height > 0,
                  measuredFormHeight.map({ abs($0 - height) > 0.5 }) ?? true else { return }
            measuredFormHeight = height
        }
        .onAppear { titleIsFocused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(schedule == nil ? "添加安排" : "编辑安排")
                .font(.headline)
                .accessibilityFocused($titleIsFocused)
            Spacer(minLength: 0)
            GlassCloseButton(accessibilityLabel: "关闭", diameter: 36, onDarkBackground: false,
                             action: close)
                .frame(width: 44, height: 44)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(minHeight: 56)
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            formSurface
            Text("只能添加今天及以后的安排；结束时间须晚于同一天的开始时间。未设置结束时间的安排仍按开始时间排序。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 15)
            if let error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    .accessibilityIdentifier("scheduleEditorError")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var formFields: some View {
        VStack(spacing: 0) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text("安排事项").font(.system(size: 16))
                    titleField
                }
                .padding(.vertical, 12)
            } else {
                HStack {
                    Text("安排事项").font(.system(size: 16))
                    titleField
                }
                .frame(minHeight: 57)
            }
            Divider()
            DatePicker("日期", selection: $date, in: Calendar.current.startOfDay(for: now)...,
                       displayedComponents: .date)
                .frame(minHeight: 57)
            Divider()
            DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
                .frame(minHeight: 57)
            Divider()
            Toggle("设置结束时间", isOn: $hasEndTime)
                .frame(minHeight: 57)
            Divider()
            DatePicker("结束时间", selection: $endTime, displayedComponents: .hourAndMinute)
                .frame(minHeight: 57)
                .disabled(!hasEndTime)
                .opacity(hasEndTime ? 1 : 0.42)
                .accessibilityHint(hasEndTime ? "" : "请先开启设置结束时间")
        }
    }

    @ViewBuilder
    private var formSurface: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(iOS 26.0, *), !reduceTransparency, colorSchemeContrast != .increased {
            formFields
                .padding(.horizontal, 15)
                .glassEffect(.regular, in: shape)
        } else if reduceTransparency || colorSchemeContrast == .increased {
            formFields
                .padding(.horizontal, 15)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
        } else {
            formFields
                .padding(.horizontal, 15)
                .background(.regularMaterial, in: shape)
        }
    }

    private var titleField: some View {
        TextField("例如：提交课程作业", text: $title)
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            .onChange(of: title) { _, newValue in
                if newValue.count > 200 { title = String(newValue.prefix(200)) }
            }
            .accessibilityIdentifier("scheduleEditorTitle")
    }

    private var saveAction: some View {
        let button = Button(schedule == nil ? "保存安排" : "保存更改") { save() }
            .font(.system(size: 15, weight: .bold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .tint(TodayStyle.color(0x2563eb))
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("scheduleEditorSave")

        return Group {
            if #available(iOS 26.0, *), !reduceTransparency, colorSchemeContrast != .increased {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var hasUnsavedChanges: Bool {
        ScheduleEditorState.isDirty(schedule: schedule, title: title, date: date,
                                    time: timeValue, endTime: endTimeValue, now: now)
    }

    private var timeValue: String { clockValue(time) }
    private var endTimeValue: String? { hasEndTime ? clockValue(endTime) : nil }

    private func clockValue(_ value: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private func close() {
        if hasUnsavedChanges { showDiscardConfirmation = true }
        else { onClose() }
    }

    private func save() {
        do {
            try onSave(schedule?.id, title, date, timeValue, endTimeValue)
            onClose()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum ScheduleEditorState {
    static func isDirty(schedule: CustomSchedule?, title: String, date: Date,
                        time: String, endTime: String? = nil, now: Date) -> Bool {
        let originalDate = schedule?.date ?? CourseScheduleCalculator.dateKey(now)
        let originalTime = schedule?.time ?? "09:00"
        return title.trimmingCharacters(in: .whitespacesAndNewlines) !=
            (schedule?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ||
            CourseScheduleCalculator.dateKey(date) != originalDate || time != originalTime ||
            endTime != schedule?.endTime
    }
}

private enum ScheduleEditorFormHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum ScheduleEditorLayout {
    private static let fixedChromeHeight: CGFloat = 132

    static func maximumFormHeight(in availableCardHeight: CGFloat) -> CGFloat {
        max(120, availableCardHeight - fixedChromeHeight)
    }

    static func formViewportHeight(contentHeight: CGFloat?, maximum: CGFloat) -> CGFloat {
        min(contentHeight ?? maximum, maximum)
    }
}
