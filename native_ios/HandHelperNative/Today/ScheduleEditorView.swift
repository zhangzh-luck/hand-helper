import SwiftUI
import UIKit

struct ScheduleEditorView: View {
    let schedule: CustomSchedule?
    let now: Date
    let onSave: (Int?, String, Date, String, String?) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var date: Date
    @State private var time: Date
    @State private var hasEndTime: Bool
    @State private var endTime: Date
    @State private var error: String?
    @State private var showDiscardConfirmation = false
    @State private var mayDismiss = false

    init(schedule: CustomSchedule?, now: Date,
         onSave: @escaping (Int?, String, Date, String, String?) throws -> Void) {
        self.schedule = schedule
        self.now = now
        self.onSave = onSave
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
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Text("安排事项").font(.system(size: 16))
                        TextField("例如：提交课程作业", text: $title)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: title) { _, newValue in
                                if newValue.count > 200 { title = String(newValue.prefix(200)) }
                            }
                    }
                    .frame(minHeight: 57)
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
                    if hasEndTime {
                        Divider()
                        DatePicker("结束时间", selection: $endTime, displayedComponents: .hourAndMinute)
                            .frame(minHeight: 57)
                    }
                }
                .padding(.horizontal, 15)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .padding(.top, 14)
                Text("只能添加今天及以后的安排；结束时间须晚于同一天的开始时间。未设置结束时间的安排仍按开始时间排序。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 15)
                if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                Button("保存安排") { save() }
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .foregroundStyle(.white)
                    .background(TodayStyle.color(0x2563eb), in: RoundedRectangle(cornerRadius: 14))
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .padding(.top, 15)
            }
            .padding(.horizontal, 18)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(schedule == nil ? "添加安排" : "编辑安排")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { close() } } }
        }
        .background(ScheduleDismissGuard(shouldConfirm: hasUnsavedChanges && !mayDismiss) {
            showDiscardConfirmation = true
        })
        .interactiveDismissDisabled(hasUnsavedChanges && !mayDismiss)
        .confirmationDialog("放弃未保存的更改？", isPresented: $showDiscardConfirmation) {
            Button("放弃更改", role: .destructive) {
                mayDismiss = true
                dismiss()
            }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("当前填写的安排尚未保存。") }
    }

    private var hasUnsavedChanges: Bool {
        ScheduleEditorState.isDirty(schedule: schedule, title: title, date: date,
                                    time: timeValue, endTime: endTimeValue, now: now)
    }

    private var timeValue: String {
        clockValue(time)
    }

    private var endTimeValue: String? { hasEndTime ? clockValue(endTime) : nil }

    private func clockValue(_ value: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private func close() {
        if hasUnsavedChanges { showDiscardConfirmation = true }
        else { mayDismiss = true; dismiss() }
    }

    private func save() {
        do {
            try onSave(schedule?.id, title, date, timeValue, endTimeValue)
            mayDismiss = true
            dismiss()
        } catch { self.error = error.localizedDescription }
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

private struct ScheduleDismissGuard: UIViewControllerRepresentable {
    let shouldConfirm: Bool
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.shouldConfirm = shouldConfirm
        context.coordinator.onAttempt = onAttempt
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            (controller.parent?.presentationController ?? controller.presentationController)?.delegate = coordinator
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var shouldConfirm = false
        var onAttempt: (() -> Void)?

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !shouldConfirm
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            onAttempt?()
        }
    }
}
