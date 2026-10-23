import SwiftUI

struct ScheduleEditorView: View {
    let schedule: CustomSchedule?
    let now: Date
    let onSave: (Int?, String, Date, String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var date: Date
    @State private var time: Date
    @State private var error: String?

    init(schedule: CustomSchedule?, now: Date,
         onSave: @escaping (Int?, String, Date, String) throws -> Void) {
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
                }
                .padding(.horizontal, 15)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .padding(.top, 14)
                Text("只能添加今天及以后的安排；时间仅用于当天排序，不会触发系统通知。")
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
        }
    }

    private func save() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let value = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        do {
            try onSave(schedule?.id, title, date, value)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
