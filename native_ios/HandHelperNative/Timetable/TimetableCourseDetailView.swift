import SwiftUI

struct TimetableCourseDetailView: View {
    let course: CourseSession

    var body: some View {
        List {
                Section("课程") {
                    LabeledContent("名称", value: course.name)
                    LabeledContent("日期", value: course.date)
                    LabeledContent("时间", value: TimetableCourseDetailText.time(course))
                    if let week = course.weekExpression, !week.isEmpty {
                        LabeledContent("周次", value: week)
                    }
                }
                Section("地点与教师") {
                    LabeledContent("教室", value: TimetableCourseDetailText.nonempty(course.room))
                    LabeledContent("教师", value: TimetableCourseDetailText.nonempty(course.teacher))
                    if let start = course.startPeriod, let end = course.endPeriod {
                        LabeledContent("节次", value: "第 \(start)–\(end) 节")
                    }
                }
        }
        .navigationTitle("课程详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum TimetableCourseDetailText {
    static func time(_ course: CourseSession) -> String {
        "\(clock(course.startDateTime))–\(clock(course.endDateTime))"
    }

    private static func clock(_ value: String) -> String {
        let parts = value.split(separator: "T", maxSplits: 1)
        guard parts.count == 2 else { return value }
        return String(parts[1].prefix(5))
    }

    static func nonempty(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "未提供" }
        return value
    }
}
