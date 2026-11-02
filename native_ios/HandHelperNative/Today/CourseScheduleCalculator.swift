import Foundation

protocol TodayClock {
    var now: Date { get }
}

struct SystemTodayClock: TodayClock { var now: Date { Date() } }

enum CourseScheduleCalculator {
    static func dateKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func teachingWeek(on day: Date, termStart: Date?, calendar: Calendar = .current) -> Int? {
        guard let termStart else { return nil }
        let start = monday(of: termStart, calendar: calendar)
        let current = monday(of: day, calendar: calendar)
        guard let days = calendar.dateComponents([.day], from: start, to: current).day, days >= 0 else { return nil }
        return days / 7 + 1
    }

    static func monday(of day: Date, calendar: Calendar = .current) -> Date {
        let weekday = calendar.component(.weekday, from: day)
        let daysFromMonday = (weekday + 5) % 7
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: noon) ?? noon
    }

    static func sessions(for day: Date, from all: [CourseSession], calendar: Calendar = .current) -> [CourseSession] {
        let key = dateKey(day, calendar: calendar)
        return all.filter { $0.date == key && $0.start != nil }
            .sorted { ($0.start ?? .distantFuture, $0.id) < ($1.start ?? .distantFuture, $1.id) }
    }

    static func applies(_ rule: ManualCourseRule, week: Int, weekday: Int) -> Bool {
        rule.weekday == weekday && rule.weeks.contains(week)
    }

    static func expandedManualCourses(
        on day: Date, rules: [ManualCourseRule], terms: [TermInfo], periods: [PeriodInfo], calendar: Calendar = .current
    ) -> [CourseSession] {
        let periodMap = Dictionary(uniqueKeysWithValues: periods.map { ($0.periodNumber, $0) })
        let key = dateKey(day, calendar: calendar)
        return rules.compactMap { rule in
            guard let term = terms.first(where: { $0.sourceTermID == rule.termSourceID }),
                  let rawStart = term.startDate,
                  let termStart = calendar.date(from: DateComponents(year: Int(rawStart.prefix(4)), month: Int(rawStart.dropFirst(5).prefix(2)), day: Int(rawStart.dropFirst(8).prefix(2)))),
                  let week = teachingWeek(on: day, termStart: termStart, calendar: calendar),
                  rule.weeks.contains(week),
                  let expandedDay = calendar.date(byAdding: .day, value: (week - 1) * 7 + rule.weekday - 1,
                                                  to: monday(of: termStart, calendar: calendar)),
                  dateKey(expandedDay, calendar: calendar) == key,
                  let first = periodMap[rule.startPeriod], let last = periodMap[rule.endPeriod],
                  let start = dateTime(day: day, clock: first.startTime, calendar: calendar),
                  let end = dateTime(day: day, clock: last.endTime, calendar: calendar) else { return nil }
            return CourseSession(
                id: -2_000_000_000 + (-rule.id) * 100 + week,
                name: rule.name, date: key,
                startDateTime: ISO8601DateFormatter().string(from: start),
                endDateTime: ISO8601DateFormatter().string(from: end),
                room: rule.room, teacher: rule.teacher,
                weekExpression: "\(rule.weeks.map(String.init).joined(separator: ","))周",
                source: "LOCAL", manualCourseID: rule.id, termID: term.id,
                weekday: rule.weekday, startPeriod: rule.startPeriod, endPeriod: rule.endPeriod
            )
        }.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    // Both Today and the weekly timetable must suppress the server copy of a
    // manual course when its locally stored rule is the authoritative copy.
    static func mergeManualCourses(remote: [CourseSession], local: [CourseSession],
                                   rules: [ManualCourseRule]) -> [CourseSession] {
        let localRemoteIDs = Set(rules.compactMap(\.remoteID))
        return (remote.filter { $0.source != "MANUAL" || !localRemoteIDs.contains($0.manualCourseID ?? Int.min) } + local)
            .sorted { ($0.start ?? .distantFuture, $0.id) < ($1.start ?? .distantFuture, $1.id) }
    }

    static func dateTime(day: Date, clock: String, calendar: Calendar = .current) -> Date? {
        let parts = clock.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    static func active(in sessions: [CourseSession], at now: Date) -> CourseSession? {
        sessions.first { ($0.start ?? .distantFuture) <= now && now < ($0.end ?? .distantPast) }
    }

    static func upcoming(in sessions: [CourseSession], at now: Date) -> CourseSession? {
        sessions.first { now < ($0.start ?? .distantPast) }
    }

    static func countdown(until end: Date, from now: Date) -> String {
        let minutes = Int(ceil(end.timeIntervalSince(now) / 60))
        return minutes > 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟"
    }
}
