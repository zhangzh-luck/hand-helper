import Foundation
import CryptoKit
import XCTest
@testable import HandHelperNative

final class WeeklyTimetableTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    private func term(_ start: String? = "2026-08-31", id: Int = 8) -> TermInfo {
        TermInfo(id: id, sourceTermID: "fall", displayName: "秋季", startDate: start, isCurrent: true)
    }

    private var periods: [PeriodInfo] {
        [PeriodInfo(periodNumber: 1, startTime: "08:30", endTime: "09:15"),
         PeriodInfo(periodNumber: 2, startTime: "09:20", endTime: "10:05"),
         PeriodInfo(periodNumber: 3, startTime: "10:25", endTime: "11:10"),
         PeriodInfo(periodNumber: 4, startTime: "11:15", endTime: "12:00")]
    }

    private func snapshot(term: TermInfo? = nil, sessions: [CourseSession] = [],
                          rules: [ManualCourseRule] = [], periods: [PeriodInfo]? = nil) -> CourseSnapshot {
        var result = CourseSnapshot.empty
        result.terms = [term ?? self.term()]
        result.periods = periods ?? self.periods
        result.calendarSessions = sessions
        result.manualRules = rules
        return result
    }

    private func session(_ id: Int, day: String = "2026-08-31", start: String = "08:30",
                         end: String = "10:05", first: Int? = nil, last: Int? = nil,
                         source: String = "IMPORTED", manualID: Int? = nil,
                         termID: Int? = 8) -> CourseSession {
        CourseSession(id: id, name: "课程 \(id)", date: day,
                      startDateTime: "\(day)T\(start):00", endDateTime: "\(day)T\(end):00",
                      room: "A101", teacher: "教师", weekExpression: "1,3周",
                      source: source, manualCourseID: manualID, termID: termID,
                      weekday: nil, startPeriod: first, endPeriod: last)
    }

    private func day(_ raw: String, calendar: Calendar) throws -> Date {
        let pieces = raw.split(separator: "-")
        return try XCTUnwrap(calendar.date(from: DateComponents(year: Int(pieces[0]),
            month: Int(pieces[1]), day: Int(pieces[2]), hour: 12)))
    }

    func testFirstWeekHolidayAndCrossYearWeeks() throws {
        XCTAssertEqual(TeachingWeekCalendar.position(on: try day("2026-08-30", calendar: utc),
                       term: term("2026-09-01"), calendar: utc), .beforeTerm)
        XCTAssertEqual(TeachingWeekCalendar.position(on: try day("2026-09-01", calendar: utc),
                       term: term("2026-09-01"), calendar: utc), .week(1))
        XCTAssertEqual(TeachingWeekCalendar.position(on: try day("2027-01-04", calendar: utc),
                       term: term("2026-12-31"), calendar: utc), .week(2))
        let week = try TeachingWeekCalendar.dates(in: 2, term: term("2026-12-31"), calendar: utc)
        XCTAssertEqual(week.map { CourseScheduleCalculator.dateKey($0, calendar: utc) },
                       ["2027-01-04", "2027-01-05", "2027-01-06", "2027-01-07",
                        "2027-01-08", "2027-01-09", "2027-01-10"])
    }

    func testManualCourseUsesFirstMondayWhenTermStartsMidweek() throws {
        let rule = ManualCourseRule(id: -1, termSourceID: "fall", name: "周一课程",
            weeks: [1], weekday: 1, startPeriod: 1, endPeriod: 2,
            room: "A101", teacher: nil, remoteID: nil)
        let stored = snapshot(term: term("2026-09-02"), rules: [rule])
        let projection = try WeeklyTimetableProjector.project(snapshot: stored,
            termID: 8, week: 1, calendar: utc)
        XCTAssertEqual(projection.dates.first, "2026-08-31")
        XCTAssertEqual(projection.placements.map(\.course.name), ["周一课程"])
        XCTAssertEqual(projection.placements.first?.weekday, 1)
    }

    func testMissingInvalidStartAndInvalidWeek() throws {
        XCTAssertEqual(TeachingWeekCalendar.position(on: try day("2026-08-31", calendar: utc),
                       term: term(nil), calendar: utc), .missingStartDate)
        XCTAssertEqual(TeachingWeekCalendar.position(on: try day("2026-08-31", calendar: utc),
                       term: term("2026-02-30"), calendar: utc), .invalidStartDate)
        XCTAssertThrowsError(try TeachingWeekCalendar.dates(in: 1, term: term(nil), calendar: utc)) {
            XCTAssertEqual($0 as? WeeklyTimetableError, .missingStartDate)
        }
        XCTAssertThrowsError(try TeachingWeekCalendar.dates(in: 1, term: term("2026-02-30"), calendar: utc)) {
            XCTAssertEqual($0 as? WeeklyTimetableError, .invalidStartDate)
        }
        XCTAssertThrowsError(try TeachingWeekCalendar.dates(in: 0, term: term(), calendar: utc))
    }

    func testCalendarUsesCalendarDaysAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        calendar.firstWeekday = 2
        let dates = try TeachingWeekCalendar.dates(in: 2, term: term("2026-03-02"), calendar: calendar)
        XCTAssertEqual(dates.map { CourseScheduleCalculator.dateKey($0, calendar: calendar) },
                       ["2026-03-09", "2026-03-10", "2026-03-11", "2026-03-12",
                        "2026-03-13", "2026-03-14", "2026-03-15"])
        XCTAssertEqual(TeachingWeekCalendar.position(on: try day("2026-03-09", calendar: calendar),
                       term: term("2026-03-02"), calendar: calendar), .week(2))
    }

    func testExplicitFallbackAndCrossPeriodPlacement() throws {
        let explicit = session(1, start: "08:31", end: "11:09", first: 1, last: 3)
        let fallback = session(2, day: "2026-09-01", start: "09:20", end: "10:05")
        let result = try WeeklyTimetableProjector.project(snapshot: snapshot(sessions: [fallback, explicit]),
                                                          termID: 8, week: 1, calendar: utc)
        XCTAssertEqual(result.dates.first, "2026-08-31")
        XCTAssertEqual(result.placements.map(\.course.id), [1, 2])
        XCTAssertEqual(result.placements[0].startPeriod, 1)
        XCTAssertEqual(result.placements[0].endPeriod, 3)
        XCTAssertEqual(result.placements[0].rowSpan, 3)
        XCTAssertEqual(result.placements[1].weekday, 2)
        XCTAssertEqual(result.placements[1].startRow, 1)
        XCTAssertTrue(result.unplaced.isEmpty)
    }

    func testUnmappedCoursesRemainDiscoverableWithReasons() throws {
        let invalidExplicit = session(1, first: 99, last: 2)
        let noStartMatch = session(2, start: "08:40")
        let backwards = session(3, start: "11:15", end: "08:30")
        let noEndMatch = session(4, end: "10:06")
        let result = try WeeklyTimetableProjector.project(snapshot: snapshot(sessions: [invalidExplicit,
            noStartMatch, backwards, noEndMatch]), termID: 8, week: 1, calendar: utc)
        XCTAssertTrue(result.placements.isEmpty)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: result.unplaced.map { ($0.course.id, $0.reason) }),
                       [1: .invalidExplicitPeriod, 2: .unmatchedStartTime,
                        3: .invalidTimeRange, 4: .unmatchedEndTime])
    }

    func testIncompleteExplicitPeriodUsesOnlyTheMissingTimeEndpoint() throws {
        let mixed = session(1, start: "08:31", end: "10:05", first: 1, last: nil)
        let result = try WeeklyTimetableProjector.project(snapshot: snapshot(sessions: [mixed]),
                                                          termID: 8, week: 1, calendar: utc)
        XCTAssertEqual(result.placements.first?.startPeriod, 1)
        XCTAssertEqual(result.placements.first?.endPeriod, 2)
    }

    func testMalformedDateAndAmbiguousPeriodRemainUnplaced() throws {
        let malformed = session(1, day: "2026-02-30")
        let ambiguous = session(2)
        let duplicatePeriods = periods + [PeriodInfo(periodNumber: 8, startTime: "08:30", endTime: "09:15")]
        let result = try WeeklyTimetableProjector.project(snapshot: snapshot(sessions: [malformed,
            ambiguous], periods: duplicatePeriods), termID: 8, week: 1, calendar: utc)
        XCTAssertEqual(result.unplaced.map(\.reason), [.invalidSessionDate, .unmatchedStartTime])
    }

    func testSelectedTermAndActualDatesDefineWeekMembership() throws {
        let weekOne = session(1)
        let weekTwo = session(2, day: "2026-09-07")
        let otherTerm = session(3, termID: 9)
        let result = try WeeklyTimetableProjector.project(snapshot: snapshot(sessions: [weekTwo,
            otherTerm, weekOne]), termID: 8, week: 1, calendar: utc)
        XCTAssertEqual(result.placements.map(\.course.id), [1])
        XCTAssertThrowsError(try WeeklyTimetableProjector.project(snapshot: snapshot(),
            termID: 9, week: 1, calendar: utc))
    }

    func testManualOddNonContiguousWeeksAndRemoteDeduplication() throws {
        let rule = ManualCourseRule(id: -1, termSourceID: "fall", name: "本地课",
                                    weeks: [1, 3, 5], weekday: 2, startPeriod: 1, endPeriod: 2,
                                    room: "B201", teacher: "老师", remoteID: 42)
        let remoteCopy = session(9, day: "2026-09-01", first: 1, last: 2,
                                 source: "MANUAL", manualID: 42)
        let input = snapshot(sessions: [remoteCopy], rules: [rule])
        let first = try WeeklyTimetableProjector.project(snapshot: input, termID: 8, week: 1, calendar: utc)
        XCTAssertEqual(first.placements.count, 1)
        XCTAssertEqual(first.placements.first?.course.source, "LOCAL")
        XCTAssertEqual(first.placements.first?.course.room, "B201")
        XCTAssertEqual(try WeeklyTimetableProjector.project(snapshot: input, termID: 8,
                        week: 2, calendar: utc).placements.count, 0)
        XCTAssertEqual(try WeeklyTimetableProjector.project(snapshot: input, termID: 8,
                        week: 3, calendar: utc).placements.count, 1)
        XCTAssertEqual(try WeeklyTimetableProjector.project(snapshot: input, termID: 8,
                        week: 4, calendar: utc).placements.count, 0)
        XCTAssertEqual(try WeeklyTimetableProjector.project(snapshot: input, termID: 8,
                        week: 5, calendar: utc).placements.count, 1)
    }

    func testManualExpansionRespectsNonUTCTimezone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let rule = ManualCourseRule(id: -1, termSourceID: "fall", name: "早课",
                                    weeks: [1], weekday: 1, startPeriod: 1, endPeriod: 2,
                                    room: nil, teacher: nil, remoteID: nil)
        let result = try WeeklyTimetableProjector.project(snapshot: snapshot(rules: [rule]),
                                                          termID: 8, week: 1, calendar: calendar)
        XCTAssertEqual(result.placements.first?.startPeriod, 1)
        XCTAssertTrue(result.unplaced.isEmpty)
    }

    func testEvenWeekRuleOnlyAppearsInSpecifiedWeeks() throws {
        let rule = ManualCourseRule(id: -2, termSourceID: "fall", name: "双周课",
                                    weeks: [2, 4], weekday: 3, startPeriod: 2, endPeriod: 3,
                                    room: nil, teacher: nil, remoteID: nil)
        let input = snapshot(rules: [rule])
        XCTAssertTrue(try WeeklyTimetableProjector.project(snapshot: input, termID: 8,
                       week: 1, calendar: utc).placements.isEmpty)
        XCTAssertEqual(try WeeklyTimetableProjector.project(snapshot: input, termID: 8,
                       week: 2, calendar: utc).placements.first?.rowSpan, 2)
        XCTAssertTrue(try WeeklyTimetableProjector.project(snapshot: input, termID: 8,
                       week: 3, calendar: utc).placements.isEmpty)
        XCTAssertEqual(try WeeklyTimetableProjector.project(snapshot: input, termID: 8,
                       week: 4, calendar: utc).placements.count, 1)
    }

    func testFullAndPartialOverlapsHaveStableLanes() throws {
        let courses = [session(3, start: "09:20", end: "11:10", first: 2, last: 3),
                       session(1, first: 1, last: 2),
                       session(2, first: 1, last: 2),
                       session(4, start: "11:15", end: "12:00", first: 4, last: 4)]
        let result = try WeeklyTimetableProjector.project(snapshot: snapshot(sessions: courses),
                                                          termID: 8, week: 1, calendar: utc)
        XCTAssertEqual(result.placements.map(\.course.id), [1, 2, 3, 4])
        XCTAssertEqual(result.placements.map(\.laneIndex), [0, 1, 2, 0])
        XCTAssertEqual(result.placements.map(\.laneCount), [3, 3, 3, 1])
        XCTAssertEqual(result.placements[0].conflictGroup, result.placements[2].conflictGroup)
        XCTAssertNotEqual(result.placements[2].conflictGroup, result.placements[3].conflictGroup)
    }

    func testIdenticalInputAndPermutationProduceStableProjection() throws {
        let courses = [session(3, start: "09:20", end: "10:05", first: 2, last: 2),
                       session(2, first: 1, last: 2), session(1, first: 1, last: 2)]
        let first = try WeeklyTimetableProjector.project(snapshot: snapshot(sessions: courses),
                                                         termID: 8, week: 1, calendar: utc)
        let repeated = try WeeklyTimetableProjector.project(snapshot: snapshot(sessions: courses),
                                                            termID: 8, week: 1, calendar: utc)
        let permuted = try WeeklyTimetableProjector.project(snapshot: snapshot(sessions: Array(courses.reversed())),
                                                            termID: 8, week: 1, calendar: utc)
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first, permuted)
    }

    func testProjectionRegeneratesFromRefreshedSnapshot() throws {
        let old = snapshot(sessions: [session(1)])
        let new = snapshot(sessions: [session(2)])
        XCTAssertEqual(try WeeklyTimetableProjector.project(snapshot: old, termID: 8,
                       week: 1, calendar: utc).placements.map(\.course.id), [1])
        XCTAssertEqual(try WeeklyTimetableProjector.project(snapshot: new, termID: 8,
                       week: 1, calendar: utc).placements.map(\.course.id), [2])
    }

    @MainActor
    func testVerifiedOwnerCacheSurvivesCookieRotationButRejectsOtherAccount() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sessionStore = ProjectionSessionStore()
        let account = VerifiedAccountContext()
        sessionStore.save(cookie: "session=alice")
        let repository = DiskCourseRepository(api: ProjectionAPI(), session: sessionStore,
                                              account: account, directory: folder)
        XCTAssertThrowsError(try repository.cached())
        try account.confirm(username: "alice", cookie: "session=alice")
        try repository.saveManualRule(ManualCourseRule(id: -1, termSourceID: "fall", name: "课",
            weeks: [1], weekday: 1, startPeriod: 1, endPeriod: 1,
            room: nil, teacher: nil, remoteID: nil))
        XCTAssertEqual(try repository.cached()?.manualRules.count, 1)
        sessionStore.save(cookie: "session=alice-new")
        XCTAssertThrowsError(try repository.cached())
        try account.confirm(username: "alice", cookie: "session=alice-new")
        XCTAssertEqual(try repository.cached()?.manualRules.count, 1)
        try account.confirm(username: "bob", cookie: "session=alice-new")
        XCTAssertNil(try repository.cached())
    }

    @MainActor
    func testCookieRotationBlocksOldTicketUntilSameOwnerIsReverified() async throws {
        let sessionStore = ProjectionSessionStore()
        sessionStore.save(cookie: "session=alice")
        let preferences = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(api: ProjectionAPI(), sessionStore: sessionStore,
                             authentication: ProjectionAuth(), preferences: preferences,
                             profileDirectory: folder)
        let repository = ProjectionRepository()
        repository.stored = snapshot(sessions: [session(1)])
        let access = WeeklyTimetableSnapshotAccess(state: state, repository: repository)
        await state.restoreSession()
        let old = try access.ticket()
        XCTAssertEqual(try access.cached(termID: 8, week: 1, calendar: utc)?.placements.count, 1)
        sessionStore.save(cookie: "session=alice-new")
        XCTAssertThrowsError(try access.ticket())
        await state.reverifyRotatedSession()
        let current = try access.ticket()
        XCTAssertEqual(current.owner, old.owner)
        XCTAssertNotEqual(current.authenticationRevision, old.authenticationRevision)
        XCTAssertThrowsError(try access.project(snapshot(sessions: [session(1)]), termID: 8,
                            week: 1, calendar: utc, ticket: old))
    }

    @MainActor
    func testUnverifiedCookieLogoutAndLateAccountResultsCannotProject() async throws {
        let sessionStore = ProjectionSessionStore()
        sessionStore.save(cookie: "session=alice")
        let preferences = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(api: ProjectionAPI(), sessionStore: sessionStore,
                             authentication: ProjectionAuth(), preferences: preferences,
                             profileDirectory: folder)
        let repository = ProjectionRepository()
        repository.stored = snapshot(sessions: [session(1)])
        let access = WeeklyTimetableSnapshotAccess(state: state, repository: repository)
        XCTAssertThrowsError(try access.ticket()) // Keychain contents are not identity proof.
        XCTAssertThrowsError(try access.cached(termID: 8, week: 1, calendar: utc))
        await state.restoreSession()
        let alice = try access.ticket()
        XCTAssertEqual(alice.owner, "user:alice")
        XCTAssertEqual(try access.project(snapshot(sessions: [session(1)]), termID: 8,
                       week: 1, calendar: utc, ticket: alice).placements.count, 1)
        await state.logout()
        XCTAssertThrowsError(try access.ticket())
        XCTAssertThrowsError(try access.project(snapshot(sessions: [session(1)]), termID: 8,
                            week: 1, calendar: utc, ticket: alice))
        await state.login(username: "bob", password: "fixture")
        XCTAssertEqual(try access.ticket().owner, "user:bob")
        XCTAssertThrowsError(try access.project(snapshot(sessions: [session(1)]), termID: 8,
                            week: 1, calendar: utc, ticket: alice))
        state.handleUnauthorized()
        XCTAssertThrowsError(try access.ticket())
    }

    @MainActor
    func testManualCreationUsesRealPeriodNumbersAndKeepsExistingCourses() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sessionStore = ProjectionSessionStore()
        sessionStore.save(cookie: "session=alice")
        let account = VerifiedAccountContext()
        try account.confirm(username: "alice", cookie: "session=alice")
        let repository = DiskCourseRepository(api: ProjectionAPI(), session: sessionStore,
                                              account: account, directory: folder)
        let existing = session(20, first: 1, last: 1)
        var stored = snapshot(sessions: [existing], periods: [periods[0], periods[2]])
        stored.manualRules = [ManualCourseRule(id: -1, termSourceID: "fall", name: "旧课程",
            weeks: [1], weekday: 1, startPeriod: 1, endPeriod: 1,
            room: nil, teacher: nil, remoteID: nil)]
        let stable = snapshotPath(folder: folder, scope: "user:alice")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: stable, options: .atomic)

        let created = try repository.createManualRule(termID: 8, name: "  新课程  ", weeks: [3, 1, 3],
            weekday: 1, startPeriod: 3, endPeriod: 3, room: " A101 ", teacher: nil)
        XCTAssertEqual(created.id, -2)
        XCTAssertEqual(created.name, "新课程")
        XCTAssertEqual(created.weeks, [1, 3])
        XCTAssertEqual(created.startPeriod, 3)
        XCTAssertEqual(try repository.cached()?.calendarSessions, [existing])
        XCTAssertEqual(try repository.cached()?.manualRules.count, 2)
        let saved = try XCTUnwrap(repository.cached())
        let projected = try WeeklyTimetableProjector.project(snapshot: saved,
            termID: 8, week: 1, calendar: utc)
        XCTAssertTrue(projected.placements.contains { $0.course.name == "新课程" })
        XCTAssertTrue(projected.placements.contains { $0.course.id == existing.id })
        let day = try self.day("2026-08-31", calendar: utc)
        XCTAssertTrue(CourseScheduleCalculator.expandedManualCourses(on: day,
            rules: saved.manualRules, terms: stored.terms,
            periods: stored.periods, calendar: utc).contains { $0.name == "新课程" })
        let today = TodayViewModel(repository: repository,
            wallpaperStore: WallpaperStore(session: sessionStore, account: account, directory: folder),
            clock: ProjectionClock(now: day))
        today.load()
        XCTAssertTrue(today.courses.contains { $0.name == "新课程" })
        XCTAssertThrowsError(try repository.createManualRule(termID: 8, name: "无效", weeks: [1],
            weekday: 1, startPeriod: 2, endPeriod: 2, room: nil, teacher: nil))
        XCTAssertEqual(try repository.cached()?.manualRules.count, 2)
    }

    @MainActor
    func testManualUpdateAndDeleteUseStableIDAndKeepTodayInSync() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sessionStore = ProjectionSessionStore()
        sessionStore.save(cookie: "session=alice")
        let account = VerifiedAccountContext()
        try account.confirm(username: "alice", cookie: "session=alice")
        let repository = DiskCourseRepository(api: ProjectionAPI(), session: sessionStore,
                                              account: account, directory: folder)
        var stored = snapshot(sessions: [session(20)], rules: [
            ManualCourseRule(id: -1, termSourceID: "fall", name: "待修改", weeks: [1],
                weekday: 1, startPeriod: 1, endPeriod: 1, room: nil, teacher: nil, remoteID: nil),
            ManualCourseRule(id: -2, termSourceID: "fall", name: "保留", weeks: [1],
                weekday: 1, startPeriod: 1, endPeriod: 1, room: nil, teacher: nil, remoteID: nil)
        ])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: snapshotPath(folder: folder, scope: "user:alice"), options: .atomic)

        let edited = try repository.updateManualRule(id: -1, termID: 8, name: "  新名称  ",
            weeks: [2, 2], weekday: 3, startPeriod: 2, endPeriod: 3,
            room: " B201 ", teacher: " 李老师 ")
        XCTAssertEqual(edited.id, -1)
        XCTAssertEqual(edited.name, "新名称")
        XCTAssertEqual(edited.weeks, [2])
        XCTAssertEqual(edited.room, "B201")
        XCTAssertEqual(edited.teacher, "李老师")
        stored = try XCTUnwrap(repository.cached())
        XCTAssertEqual(stored.manualRules.count, 2)
        XCTAssertEqual(stored.manualRules.first(where: { $0.id == -2 })?.name, "保留")
        let firstWeek = try WeeklyTimetableProjector.project(snapshot: stored, termID: 8,
                                                               week: 1, calendar: utc)
        XCTAssertFalse(firstWeek.placements.contains { $0.course.name == "新名称" })
        let secondWeek = try WeeklyTimetableProjector.project(snapshot: stored, termID: 8,
                                                                week: 2, calendar: utc)
        XCTAssertTrue(secondWeek.placements.contains {
            $0.course.manualCourseID == -1 && $0.weekday == 3 && $0.startRow == 1 && $0.rowSpan == 2
        })
        let today = TodayViewModel(repository: repository,
            wallpaperStore: WallpaperStore(session: sessionStore, account: account, directory: folder),
            clock: ProjectionClock(now: try day("2026-09-09", calendar: .current)))
        today.load()
        XCTAssertTrue(today.courses.contains { $0.manualCourseID == -1 && $0.name == "新名称" })

        sessionStore.save(cookie: "session=alice-new")
        XCTAssertThrowsError(try repository.deleteManualRule(id: -1, termID: 8))
        try account.confirm(username: "alice", cookie: "session=alice-new")
        try repository.deleteManualRule(id: -1, termID: 8)
        XCTAssertThrowsError(try repository.deleteManualRule(id: -1, termID: 8))
        stored = try XCTUnwrap(repository.cached())
        XCTAssertEqual(stored.manualRules.map(\.id), [-2])
        XCTAssertEqual(stored.calendarSessions.map(\.id), [20])
        today.load()
        XCTAssertFalse(today.courses.contains { $0.manualCourseID == -1 })
        try account.confirm(username: "bob", cookie: "session=alice-new")
        XCTAssertThrowsError(try repository.deleteManualRule(id: -2, termID: 8))
        try account.confirm(username: "alice", cookie: "session=alice-new")
        XCTAssertEqual(try repository.cached()?.manualRules.map(\.id), [-2])
    }

    @MainActor
    func testLegacyCookieSnapshotMigratesOnlyAfterCurrentOwnerVerification() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = snapshot(rules: [ManualCourseRule(id: -1, termSourceID: "fall", name: "旧规则",
            weeks: [1], weekday: 1, startPeriod: 1, endPeriod: 1,
            room: nil, teacher: nil, remoteID: nil)])
        try JSONEncoder().encode(old).write(to: snapshotPath(folder: folder, scope: "session=alice"),
                                               options: .atomic)
        let sessionStore = ProjectionSessionStore()
        sessionStore.save(cookie: "session=alice")
        let account = VerifiedAccountContext()
        let repository = DiskCourseRepository(api: ProjectionAPI(), session: sessionStore,
                                              account: account, directory: folder)
        XCTAssertThrowsError(try repository.cached())
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            snapshotPath(folder: folder, scope: "user:alice").path))
        try account.confirm(username: "alice", cookie: "session=alice")
        XCTAssertEqual(try repository.cached()?.manualRules.first?.name, "旧规则")
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            snapshotPath(folder: folder, scope: "user:alice").path))
        sessionStore.save(cookie: "session=alice-new")
        XCTAssertThrowsError(try repository.cached())
        try account.confirm(username: "alice", cookie: "session=alice-new")
        XCTAssertEqual(try repository.cached()?.manualRules.first?.name, "旧规则")
    }

    private func snapshotPath(folder: URL, scope: String) -> URL {
        let base = APIConfiguration.development.baseURL.absoluteString
        let digest = SHA256.hash(data: Data("\(base)|\(scope)".utf8))
        return folder.appendingPathComponent("course_snapshot_\(digest.map { String(format: "%02x", $0) }.joined()).json")
    }
}

private struct ProjectionClock: TodayClock {
    let now: Date
}

private final class ProjectionSessionStore: SessionStore {
    private(set) var cookie: String?
    func save(cookie: String) { self.cookie = cookie }
    @discardableResult func clear() -> Bool { cookie = nil; return true }
}

private final class ProjectionAuth: AuthenticationClientProtocol {
    func login(username: String, password: String) async throws -> (cookie: String, identity: VerifiedIdentity) {
        ("session=\(username)", VerifiedIdentity(authenticated: true, username: username))
    }
    func verify(cookie: String) async throws -> VerifiedIdentity {
        let owner = String(cookie.dropFirst("session=".count)).split(separator: "-").first.map(String.init) ?? ""
        return VerifiedIdentity(authenticated: true, username: owner)
    }
    func logout(cookie: String) async throws {}
}

private final class ProjectionAPI: APIClientProtocol {
    func request<Value: Decodable>(_ method: String, path: String, body: Data?,
                                   preserveSessionOnPasswordError: Bool) async throws -> Value {
        throw APIError.invalidResponse
    }
}

@MainActor
private final class ProjectionRepository: CourseRepository {
    var stored: CourseSnapshot?
    var sessionCookie: String? { nil }
    var canEditSchedules: Bool { false }
    func cached() throws -> CourseSnapshot? { stored }
    func refresh(on date: Date) async throws -> CourseSnapshot { throw APIError.invalidResponse }
    func localSchedules(on date: Date) throws -> [CustomSchedule] { [] }
    func allLocalSchedules() throws -> [CustomSchedule] { [] }
    func saveSchedule(_ schedule: CustomSchedule) throws {}
    func deleteSchedule(id: Int) throws {}
    func saveManualRule(_ rule: ManualCourseRule) throws {}
    func saveProfile(_ profile: TodayProfile) throws {}
}
