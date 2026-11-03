import Foundation

enum ScheduleTimeRange {
    static func minutes(_ value: String) -> Int? {
        let characters = Array(value.utf8)
        guard characters.count == 5, characters[2] == 58,
              characters.enumerated().allSatisfy({ $0.offset == 2 || (48...57).contains($0.element) }) else {
            return nil
        }
        let hour = Int(characters[0] - 48) * 10 + Int(characters[1] - 48)
        let minute = Int(characters[3] - 48) * 10 + Int(characters[4] - 48)
        guard hour < 24, minute < 60 else { return nil }
        return hour * 60 + minute
    }

    static func valid(start: String, end: String) -> Bool {
        guard let first = minutes(start), let last = minutes(end) else { return false }
        return last > first
    }

    static func date(_ day: String, time: String, calendar: Calendar = .current) -> Date? {
        guard let minutes = minutes(time), day.count == 10 else { return nil }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              CourseScheduleCalculator.dateKey(start, calendar: calendar) == day else { return nil }
        guard let result = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60,
                                         second: 0, of: start),
              CourseScheduleCalculator.dateKey(result, calendar: calendar) == day else { return nil }
        return result
    }
}
