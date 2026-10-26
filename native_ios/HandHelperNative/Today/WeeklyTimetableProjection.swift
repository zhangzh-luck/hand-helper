import Foundation

enum TeachingWeekPosition: Equatable {
    case missingStartDate
    case invalidStartDate
    case beforeTerm
    case week(Int)
}

enum WeeklyTimetableError: Error, Equatable {
    case unknownTerm
    case invalidWeek
    case missingStartDate
    case invalidStartDate
}

/// Dates are calculated at local noon in the supplied calendar. This keeps a
/// week stable across daylight-saving transitions without relying on 24-hour durations.
enum TeachingWeekCalendar {
    static func position(on day: Date, term: TermInfo, calendar: Calendar) -> TeachingWeekPosition {
        guard term.startDate != nil else { return .missingStartDate }
        guard let start = startDate(for: term, calendar: calendar) else { return .invalidStartDate }
        guard let week = CourseScheduleCalculator.teachingWeek(on: day, termStart: start, calendar: calendar) else {
            return .beforeTerm
        }
        return .week(week)
    }

    static func dates(in week: Int, term: TermInfo, calendar: Calendar) throws -> [Date] {
        guard week > 0 else { throw WeeklyTimetableError.invalidWeek }
        guard term.startDate != nil else { throw WeeklyTimetableError.missingStartDate }
        guard let start = startDate(for: term, calendar: calendar) else {
            throw WeeklyTimetableError.invalidStartDate
        }
        let firstMonday = CourseScheduleCalculator.monday(of: start, calendar: calendar)
        let (offset, overflow) = (week - 1).multipliedReportingOverflow(by: 7)
        guard !overflow,
              let monday = calendar.date(byAdding: .day, value: offset, to: firstMonday) else {
            throw WeeklyTimetableError.invalidWeek
        }
        return try (0..<7).map { day in
            guard let date = calendar.date(byAdding: .day, value: day, to: monday) else {
                throw WeeklyTimetableError.invalidWeek
            }
            return date
        }
    }

    private static func startDate(for term: TermInfo, calendar: Calendar) -> Date? {
        guard let raw = term.startDate else { return nil }
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else {
            return nil
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day ? date : nil
    }
}

enum UnplacedCourseReason: Error, Equatable {
    case invalidSessionDate
    case invalidTimeRange
    case invalidExplicitPeriod
    case unmatchedStartTime
    case unmatchedEndTime
}

struct UnplacedCourse: Equatable {
    let course: CourseSession
    let reason: UnplacedCourseReason
}

struct WeeklyCoursePlacement: Equatable {
    let course: CourseSession
    let weekday: Int
    let startPeriod: Int
    let endPeriod: Int
    let startRow: Int
    let rowSpan: Int
    let conflictGroup: Int
    let laneIndex: Int
    let laneCount: Int
}

struct WeeklyTimetableProjection: Equatable {
    let term: TermInfo
    let week: Int
    let dates: [String]
    let placements: [WeeklyCoursePlacement]
    let unplaced: [UnplacedCourse]
}

enum WeeklyTimetableProjector {
    static func project(snapshot: CourseSnapshot, termID: Int, week: Int,
                        calendar: Calendar) throws -> WeeklyTimetableProjection {
        guard let term = snapshot.terms.first(where: { $0.id == termID }) else {
            throw WeeklyTimetableError.unknownTerm
        }
        let days = try TeachingWeekCalendar.dates(in: week, term: term, calendar: calendar)
        let dateKeys = days.map { CourseScheduleCalculator.dateKey($0, calendar: calendar) }
        let dateSet = Set(dateKeys)
        let rules = snapshot.manualRules.filter { $0.termSourceID == term.sourceTermID }
        let relevantRemote = snapshot.calendarSessions.filter { $0.termID == term.id }
        let orderedPeriods = snapshot.periods.sorted {
            ($0.periodNumber, $0.startTime, $0.endTime) < ($1.periodNumber, $1.startTime, $1.endTime)
        }
        var candidates: [CourseSession] = []
        for (day, key) in zip(days, dateKeys) {
            let remote = relevantRemote.filter { $0.date == key }
            let local = CourseScheduleCalculator.expandedManualCourses(
                on: day, rules: rules, terms: [term], periods: snapshot.periods, calendar: calendar)
            candidates += CourseScheduleCalculator.mergeManualCourses(remote: remote, local: local, rules: rules)
        }
        // A malformed date cannot be assigned a day, but must remain discoverable.
        let invalidDates = relevantRemote.filter { !validDateKey($0.date, calendar: calendar) }
        var unplaced = invalidDates.map { UnplacedCourse(course: $0, reason: .invalidSessionDate) }
        var resolved: [ResolvedCourse] = []
        for course in candidates where dateSet.contains(course.date) {
            guard let weekday = dateKeys.firstIndex(of: course.date).map({ $0 + 1 }) else { continue }
            switch resolve(course, periods: orderedPeriods, calendar: calendar) {
            case .success(let rows):
                resolved.append(ResolvedCourse(course: course, weekday: weekday,
                                               start: rows.start, end: rows.end,
                                               startRow: rows.startRow, endRow: rows.endRow))
            case .failure(let reason):
                unplaced.append(UnplacedCourse(course: course, reason: reason))
            }
        }
        resolved.sort { stableKey($0) < stableKey($1) }
        unplaced.sort { unplacedKey($0) < unplacedKey($1) }
        return WeeklyTimetableProjection(term: term, week: week, dates: dateKeys,
                                         placements: assignLanes(resolved), unplaced: unplaced)
    }

    private struct ResolvedCourse {
        let course: CourseSession
        let weekday: Int
        let start: Int
        let end: Int
        let startRow: Int
        let endRow: Int
    }

    private struct Rows {
        let start: Int
        let end: Int
        let startRow: Int
        let endRow: Int
    }

    private static func resolve(_ course: CourseSession, periods: [PeriodInfo], calendar: Calendar)
        -> Result<Rows, UnplacedCourseReason> {
        guard let startClock = clock(course.startDateTime, day: course.date, calendar: calendar),
              let endClock = clock(course.endDateTime, day: course.date, calendar: calendar),
              startClock.minutes < endClock.minutes else {
            return .failure(.invalidTimeRange)
        }
        let start: Int
        if let explicit = course.startPeriod {
            guard periods.filter({ $0.periodNumber == explicit }).count == 1 else {
                return .failure(.invalidExplicitPeriod)
            }
            start = explicit
        } else {
            let matches = periods.filter { $0.startTime == startClock.text }
            guard matches.count == 1 else { return .failure(.unmatchedStartTime) }
            start = matches[0].periodNumber
        }
        let end: Int
        if let explicit = course.endPeriod {
            guard periods.filter({ $0.periodNumber == explicit }).count == 1 else {
                return .failure(.invalidExplicitPeriod)
            }
            end = explicit
        } else {
            let matches = periods.filter { $0.endTime == endClock.text }
            guard matches.count == 1 else { return .failure(.unmatchedEndTime) }
            end = matches[0].periodNumber
        }
        guard let startRow = periods.firstIndex(where: { $0.periodNumber == start }),
              let endRow = periods.firstIndex(where: { $0.periodNumber == end }),
              startRow <= endRow else { return .failure(.invalidExplicitPeriod) }
        return .success(Rows(start: start, end: end, startRow: startRow, endRow: endRow))
    }

    private static func clock(_ raw: String, day: String, calendar: Calendar) -> (text: String, minutes: Int)? {
        let parts = raw.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        // Local rules use ISO8601 instants, while server sessions use naive
        // campus wall times. Convert only the former through the calendar.
        if raw.hasSuffix("Z") || parts[1].contains("+") || parts[1].dropFirst(8).contains("-") {
            guard let instant = BackendDate.parse(raw),
                  CourseScheduleCalculator.dateKey(instant, calendar: calendar) == day else { return nil }
            let components = calendar.dateComponents([.hour, .minute], from: instant)
            guard let hour = components.hour, let minute = components.minute else { return nil }
            return (String(format: "%02d:%02d", hour, minute), hour * 60 + minute)
        }
        guard String(parts[0]) == day else { return nil }
        let time = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard time.count >= 2, time[0].count == 2, time[1].count == 2,
              let hour = Int(time[0]), let minute = Int(time[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return (String(format: "%02d:%02d", hour, minute), hour * 60 + minute)
    }

    private static func validDateKey(_ raw: String, calendar: Calendar) -> Bool {
        let term = TermInfo(id: 0, sourceTermID: "", displayName: "", startDate: raw, isCurrent: false)
        return raw.count == 10 &&
            TeachingWeekCalendar.position(on: Date(timeIntervalSince1970: 0), term: term,
                                          calendar: calendar) != .invalidStartDate
    }

    private static func stableKey(_ item: ResolvedCourse) -> (Int, Int, Int, String, String, Int) {
        (item.weekday, item.startRow, item.endRow, item.course.name,
         item.course.source ?? "", item.course.id)
    }

    private static func unplacedKey(_ item: UnplacedCourse) -> (String, String, Int) {
        (item.course.date, item.course.name, item.course.id)
    }

    private static func assignLanes(_ courses: [ResolvedCourse]) -> [WeeklyCoursePlacement] {
        var output: [WeeklyCoursePlacement] = []
        var index = 0
        var groupNumber = 0
        while index < courses.count {
            let day = courses[index].weekday
            var end = index + 1
            var groupEnd = courses[index].endRow
            while end < courses.count && courses[end].weekday == day && courses[end].startRow <= groupEnd {
                groupEnd = max(groupEnd, courses[end].endRow)
                end += 1
            }
            var laneEnds: [Int] = []
            var lanes: [Int] = []
            for item in courses[index..<end] {
                if let lane = laneEnds.firstIndex(where: { $0 < item.startRow }) {
                    laneEnds[lane] = item.endRow
                    lanes.append(lane)
                } else {
                    lanes.append(laneEnds.count)
                    laneEnds.append(item.endRow)
                }
            }
            for (offset, item) in courses[index..<end].enumerated() {
                output.append(WeeklyCoursePlacement(course: item.course, weekday: day,
                    startPeriod: item.start, endPeriod: item.end, startRow: item.startRow,
                    rowSpan: item.endRow - item.startRow + 1, conflictGroup: groupNumber,
                    laneIndex: lanes[offset], laneCount: laneEnds.count))
            }
            groupNumber += 1
            index = end
        }
        return output
    }
}

struct WeeklyTimetableAccountTicket: Equatable {
    let owner: String
    let authenticationRevision: Int
}

/// Reads only the existing repository. Call `project` again with a refreshed
/// snapshot; the projection itself never owns a cache or initiates a request.
@MainActor
struct WeeklyTimetableSnapshotAccess {
    let state: AppState
    let repository: any CourseRepository

    func ticket() throws -> WeeklyTimetableAccountTicket {
        let revision = state.authenticationRevision
        return WeeklyTimetableAccountTicket(owner: try state.requireCurrentAccount(revision: revision),
                                            authenticationRevision: revision)
    }

    func cached(termID: Int, week: Int, calendar: Calendar) throws -> WeeklyTimetableProjection? {
        let current = try ticket()
        guard let snapshot = try repository.cached() else { return nil }
        return try project(snapshot, termID: termID, week: week, calendar: calendar, ticket: current)
    }

    func project(_ snapshot: CourseSnapshot, termID: Int, week: Int, calendar: Calendar,
                 ticket: WeeklyTimetableAccountTicket) throws -> WeeklyTimetableProjection {
        guard try state.requireCurrentAccount(revision: ticket.authenticationRevision) == ticket.owner else {
            throw APIError.unauthorized(message: "登录账号已变化。")
        }
        return try WeeklyTimetableProjector.project(snapshot: snapshot, termID: termID,
                                                    week: week, calendar: calendar)
    }
}
