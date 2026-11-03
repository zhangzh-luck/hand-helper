import Foundation
import XCTest
@testable import HandHelperNative

final class LiveActivityTests: XCTestCase {
    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ value: String) -> Date { BackendDate.parse(value)! }

    private func course(id: Int, name: String = "课程", start: String = "08:30", end: String = "10:00") -> CourseSession {
        CourseSession(id: id, name: name, date: "2026-10-23",
            startDateTime: "2026-10-23T\(start):00Z", endDateTime: "2026-10-23T\(end):00Z",
            room: "A101", teacher: nil, weekExpression: nil, source: "IMPORTED",
            manualCourseID: nil, termID: 1, weekday: nil, startPeriod: nil, endPeriod: nil)
    }

    private func snapshot(_ sessions: [CourseSession] = []) -> CourseSnapshot {
        var result = CourseSnapshot.empty
        result.calendarSessions = sessions
        return result
    }

    private func resolve(_ snapshot: CourseSnapshot, schedules: [CustomSchedule] = [],
                         at instant: String = "2026-10-23T09:00:00Z", owner: String = "user:alice") -> CurrentActivityItem? {
        CurrentActivityResolver.current(snapshot: snapshot, schedules: schedules, owner: owner,
                                        at: date(instant), calendar: utc)
    }

    func testLegacyScheduleAndOptionalEndTimeEncoding() throws {
        let old = try JSONDecoder().decode(CustomSchedule.self, from:
            Data(#"{"id":-1,"title":"旧安排","scheduled_date":"2026-10-23","scheduled_time":"09:00"}"#.utf8))
        XCTAssertNil(old.endTime)
        let updated = CustomSchedule(id: old.id, title: old.title, date: old.date,
                                     time: old.time, endTime: "10:00")
        XCTAssertEqual(try JSONDecoder().decode(CustomSchedule.self, from: JSONEncoder().encode(updated)), updated)
        XCTAssertNil(try JSONDecoder().decode(CustomSchedule.self,
            from: JSONEncoder().encode(CustomSchedule(id: old.id, title: old.title,
                                                       date: old.date, time: old.time))).endTime)
    }

    func testStrictSameDayTimeValidationAndUntimedSchedule() {
        XCTAssertEqual(ScheduleTimeRange.minutes("09:05"), 545)
        for invalid in ["9:05", "24:00", "09:60", "09:00Z", "ab:cd"] {
            XCTAssertNil(ScheduleTimeRange.minutes(invalid))
        }
        XCTAssertTrue(ScheduleTimeRange.valid(start: "09:00", end: "10:00"))
        XCTAssertFalse(ScheduleTimeRange.valid(start: "09:00", end: "09:00"))
        XCTAssertFalse(ScheduleTimeRange.valid(start: "23:30", end: "00:30"))
        let untimed = CustomSchedule(id: -1, title: "仅提醒", date: "2026-10-23", time: "09:00")
        XCTAssertNil(resolve(snapshot(), schedules: [untimed]))
    }

    func testCourseBoundariesAndStableIdentity() throws {
        let source = snapshot([course(id: 7)])
        XCTAssertNil(resolve(source, at: "2026-10-23T08:29:59Z"))
        let started = try XCTUnwrap(resolve(source, at: "2026-10-23T08:30:00Z"))
        XCTAssertEqual(started.kind, .course)
        XCTAssertEqual(started.location, "A101")
        XCTAssertEqual(resolve(source, at: "2026-10-23T09:59:59Z")?.id, started.id)
        XCTAssertNil(resolve(source, at: "2026-10-23T10:00:00Z"))
        XCTAssertNotEqual(resolve(source, owner: "user:bob")?.id, started.id)
    }

    func testCoursePriorityAndStableOverlapOrder() {
        let schedules = [CustomSchedule(id: -2, title: "安排二", date: "2026-10-23", time: "08:50", endTime: "10:00"),
                         CustomSchedule(id: -1, title: "安排一", date: "2026-10-23", time: "08:30", endTime: "10:00")]
        XCTAssertEqual(resolve(snapshot([course(id: 5)]), schedules: schedules)?.kind, .course)
        XCTAssertEqual(resolve(snapshot(), schedules: schedules)?.title, "安排一")
        let first = resolve(snapshot([course(id: 2), course(id: 1)]))
        let reversed = resolve(snapshot([course(id: 1), course(id: 2)]))
        XCTAssertEqual(first?.id, reversed?.id)
    }

    func testConsecutiveSameNamedCoursesAndInvalidTimes() {
        let early = course(id: 1, name: "机器学习", start: "08:30", end: "09:00")
        let late = course(id: 2, name: "机器学习", start: "09:00", end: "10:00")
        let source = snapshot([early, late])
        let first = resolve(source, at: "2026-10-23T08:59:00Z")
        let second = resolve(source, at: "2026-10-23T09:00:00Z")
        XCTAssertNotEqual(first?.id, second?.id)
        let broken = CourseSession(id: 3, name: "坏时间", date: "2026-10-23",
            startDateTime: "invalid", endDateTime: "invalid", room: nil, teacher: nil,
            weekExpression: nil, source: "IMPORTED", manualCourseID: nil,
            termID: 1, weekday: nil, startPeriod: nil, endPeriod: nil)
        XCTAssertNil(resolve(snapshot([broken])))
    }

    func testManualCourseWeekProjectionUsesRealPeriodTimes() {
        var source = CourseSnapshot.empty
        source.terms = [TermInfo(id: 1, sourceTermID: "fall", displayName: "秋季",
                                 startDate: "2026-10-19", isCurrent: true)]
        source.periods = [PeriodInfo(periodNumber: 1, startTime: "08:30", endTime: "09:15")]
        source.manualRules = [ManualCourseRule(id: -1, termSourceID: "fall", name: "手动课",
            weeks: [1, 3], weekday: 5, startPeriod: 1, endPeriod: 1,
            room: nil, teacher: nil, remoteID: nil)]
        XCTAssertEqual(resolve(source, at: "2026-10-23T09:00:00Z")?.title, "手动课")
        XCTAssertNil(resolve(source, at: "2026-10-30T09:00:00Z"))
    }

    func testReconciliationLifecycleAndPermission() {
        let start = date("2026-10-23T08:30:00Z")
        let end = date("2026-10-23T10:00:00Z")
        let item = CurrentActivityItem(id: "one", kind: .course, title: "课程", start: start,
                                       end: end, location: "A101")
        let state = HandHelperActivityAttributes.ContentState(kind: "course", title: "课程",
                                                              start: start, end: end, location: "A101")
        let record = LiveActivityRecord(systemID: "activity", itemID: "one", state: state)
        XCTAssertEqual(LiveActivityReconciliation.plan(records: [], item: nil,
                                                       allowed: true, foreground: true), [])
        XCTAssertEqual(LiveActivityReconciliation.plan(records: [], item: item,
                                                       allowed: true, foreground: false), [])
        XCTAssertEqual(LiveActivityReconciliation.plan(records: [], item: item,
                                                       allowed: true, foreground: true), [.start(item)])
        XCTAssertEqual(LiveActivityReconciliation.plan(records: [record], item: item,
                                                       allowed: true, foreground: true), [])
        XCTAssertEqual(LiveActivityReconciliation.plan(records: [record], item: nil,
                                                       allowed: true, foreground: true), [.end("activity")])
        XCTAssertEqual(LiveActivityReconciliation.plan(records: [record], item: item,
                                                       allowed: false, foreground: true), [.end("activity")])
        let changed = CurrentActivityItem(id: "one", kind: .course, title: "新名称", start: start,
                                          end: end, location: "A101")
        XCTAssertEqual(LiveActivityReconciliation.plan(records: [record], item: changed,
                                                       allowed: true, foreground: true), [.update("activity", changed)])
        let next = CurrentActivityItem(id: "two", kind: .schedule, title: "安排", start: start,
                                       end: end, location: nil)
        XCTAssertEqual(LiveActivityReconciliation.plan(records: [record], item: next,
                                                       allowed: true, foreground: true), [.end("activity"), .start(next)])
        XCTAssertEqual(LiveActivityReconciliation.plan(records: [record], item: item,
                                                       allowed: true, foreground: false), [])
        XCTAssertEqual(LiveActivityReconciliation.plan(records: [record], item: item,
                                                       allowed: false, foreground: false), [.end("activity")])
        let ended = LiveActivityRecord(systemID: "old", itemID: "one", state: state, status: .ended)
        XCTAssertEqual(LiveActivityReconciliation.plan(records: [ended], item: item,
                                                       allowed: true, foreground: true), [.start(item)])
    }

    @MainActor
    func testRequestFailureIsVisibleAndDoesNotCreateActivity() async {
        let driver = MockLiveActivityDriver()
        driver.shouldFail = true
        let diagnostics = LiveActivityDiagnostics()
        let item = CurrentActivityItem(id: "test", kind: .course, title: "测试",
            start: date("2026-10-23T08:30:00Z"), end: date("2026-10-23T10:00:00Z"), location: nil)
        await LiveActivityActionExecutor.execute([.start(item)], driver: driver,
            diagnostics: diagnostics, version: 1, reason: "test", selected: "test",
            foreground: true, isCurrent: { true })
        XCTAssertEqual(driver.startCount, 1)
        XCTAssertTrue(driver.records().isEmpty)
        XCTAssertTrue(diagnostics.lastOutcome.contains("request failed"))
        XCTAssertTrue(diagnostics.lastOutcome.contains("code=17"))
    }

    @MainActor
    func testForegroundRequestIsNotImmediatelyEndedOnBackgroundSync() async {
        let driver = MockLiveActivityDriver()
        let diagnostics = LiveActivityDiagnostics()
        let item = CurrentActivityItem(id: "test", kind: .course, title: "测试",
            start: date("2026-10-23T08:30:00Z"), end: date("2026-10-23T10:00:00Z"), location: nil)
        let actions = LiveActivityReconciliation.plan(records: driver.records(), item: item,
                                                      allowed: true, foreground: true)
        await LiveActivityActionExecutor.execute(actions, driver: driver,
            diagnostics: diagnostics, version: 1, reason: "scene_active", selected: "test",
            foreground: true, isCurrent: { true })
        XCTAssertEqual(driver.startCount, 1)
        let background = LiveActivityReconciliation.plan(records: driver.records(), item: item,
                                                         allowed: true, foreground: false)
        XCTAssertTrue(background.isEmpty)
        XCTAssertEqual(driver.endCount, 0)
        XCTAssertTrue(diagnostics.lastOutcome.contains("request succeeded"))
    }

    @MainActor
    func testStaleGenerationSkipsPlannedRequest() async {
        let driver = MockLiveActivityDriver()
        let item = CurrentActivityItem(id: "test", kind: .schedule, title: "测试",
            start: date("2026-10-23T08:30:00Z"), end: date("2026-10-23T10:00:00Z"), location: nil)
        await LiveActivityActionExecutor.execute([.start(item)], driver: driver,
            diagnostics: LiveActivityDiagnostics(), version: 1, reason: "stale", selected: "test",
            foreground: true, isCurrent: { false })
        XCTAssertEqual(driver.startCount, 0)
    }
}

@MainActor
private final class MockLiveActivityDriver: LiveActivityDriving {
    var isAvailable = true
    var shouldFail = false
    var startCount = 0
    var endCount = 0
    private var stored: [LiveActivityRecord] = []

    func records() -> [LiveActivityRecord] { stored }

    func start(item: CurrentActivityItem) async throws -> String {
        startCount += 1
        if shouldFail { throw NSError(domain: "TestLiveActivity", code: 17) }
        let id = "mock-\(startCount)"
        stored.append(LiveActivityRecord(systemID: id, itemID: item.id,
            state: HandHelperActivityAttributes.ContentState(kind: item.kind.rawValue,
                title: item.title, start: item.start, end: item.end, location: item.location)))
        return id
    }

    func update(systemID: String, item: CurrentActivityItem) async {
        guard let index = stored.firstIndex(where: { $0.systemID == systemID }) else { return }
        stored[index] = LiveActivityRecord(systemID: systemID, itemID: item.id,
            state: HandHelperActivityAttributes.ContentState(kind: item.kind.rawValue,
                title: item.title, start: item.start, end: item.end, location: item.location))
    }

    func end(systemID: String) async {
        endCount += 1
        stored.removeAll { $0.systemID == systemID }
    }
}
