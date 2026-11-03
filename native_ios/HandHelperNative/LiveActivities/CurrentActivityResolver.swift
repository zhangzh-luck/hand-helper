import CryptoKit
import Foundation

struct CurrentActivityItem: Equatable {
    enum Kind: String { case course, schedule }

    let id: String
    let kind: Kind
    let title: String
    let start: Date
    let end: Date
    let location: String?

}

enum CurrentActivityResolver {
    static func current(snapshot: CourseSnapshot, schedules: [CustomSchedule], owner: String,
                        at now: Date, calendar: Calendar = .current) -> CurrentActivityItem? {
        let local = CourseScheduleCalculator.expandedManualCourses(
            on: now, rules: snapshot.manualRules, terms: snapshot.terms,
            periods: snapshot.periods, calendar: calendar)
        let remote = CourseScheduleCalculator.sessions(for: now, from: snapshot.calendarSessions, calendar: calendar)
        let courses = CourseScheduleCalculator.mergeManualCourses(remote: remote, local: local,
                                                                  rules: snapshot.manualRules)
        let courseItems = courses.compactMap { course -> CurrentActivityItem? in
            guard let start = course.start, let end = course.end, end > start,
                  start <= now, now < end else { return nil }
            let sourceID = course.manualCourseID.map(String.init) ?? String(course.id)
            return CurrentActivityItem(id: stableID(owner: owner, kind: "course",
                         source: "\(course.source ?? "unknown"):\(sourceID):\(course.date)"),
                kind: .course, title: course.name, start: start, end: end, location: course.room)
        }
        if let first = courseItems.sorted(by: ordered).first { return first }

        return schedules.compactMap { schedule -> CurrentActivityItem? in
            guard let endTime = schedule.endTime,
                  ScheduleTimeRange.valid(start: schedule.time, end: endTime),
                  let start = ScheduleTimeRange.date(schedule.date, time: schedule.time, calendar: calendar),
                  let end = ScheduleTimeRange.date(schedule.date, time: endTime, calendar: calendar),
                  start <= now, now < end else { return nil }
            return CurrentActivityItem(id: stableID(owner: owner, kind: "schedule",
                        source: "\(schedule.id):\(schedule.date)"),
                kind: .schedule, title: schedule.title, start: start, end: end, location: nil)
        }.sorted(by: ordered).first
    }

    static func nextBoundary(snapshot: CourseSnapshot, schedules: [CustomSchedule],
                             after now: Date, calendar: Calendar = .current) -> Date? {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let local = [now, tomorrow].flatMap {
            CourseScheduleCalculator.expandedManualCourses(on: $0, rules: snapshot.manualRules,
                terms: snapshot.terms, periods: snapshot.periods, calendar: calendar)
        }
        let courseTimes = (snapshot.calendarSessions + local).flatMap { [$0.start, $0.end] }.compactMap { $0 }
        let scheduleTimes = schedules.flatMap { schedule -> [Date] in
            guard let end = schedule.endTime, ScheduleTimeRange.valid(start: schedule.time, end: end) else {
                return []
            }
            return [ScheduleTimeRange.date(schedule.date, time: schedule.time, calendar: calendar),
                    ScheduleTimeRange.date(schedule.date, time: end, calendar: calendar)].compactMap { $0 }
        }
        let midnight = calendar.startOfDay(for: tomorrow)
        return (courseTimes + scheduleTimes + [midnight]).filter { $0 > now }.min()
    }

    private static func ordered(_ lhs: CurrentActivityItem, _ rhs: CurrentActivityItem) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.id < rhs.id
    }

    private static func stableID(owner: String, kind: String, source: String) -> String {
        SHA256.hash(data: Data("\(owner)|\(kind)|\(source)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
