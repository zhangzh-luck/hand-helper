import CryptoKit
import XCTest
@testable import HandHelperNative

final class TodayTests: XCTestCase {
    func testWallpaperDataURLDecoding() {
        XCTAssertEqual(WallpaperStore.decodeDataURL("data:image/png;base64,AQID"), Data([1, 2, 3]))
        XCTAssertNil(WallpaperStore.decodeDataURL("data:image/png;base64,not-base64!"))
        XCTAssertNil(WallpaperStore.decodeDataURL("data:image/png;base64"))
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    private func date(_ raw: String) -> Date { BackendDate.parse(raw)! }
    private func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func session(id: Int, day: String, start: String, end: String) throws -> CourseSession {
        let json = """
        {"id":\(id),"course_name":"课程 \(id)","session_date":"\(day)",
         "start_datetime":"\(start)","end_datetime":"\(end)",
         "classroom":"A101","teacher":"老师","source":"IMPORT"}
        """
        return try JSONDecoder().decode(CourseSession.self, from: Data(json.utf8))
    }

    func testBackendFieldsAndTodayFilteringAndSorting() throws {
        let late = try session(id: 2, day: "2026-10-23", start: "2026-10-23T14:00:00Z", end: "2026-10-23T15:00:00Z")
        let early = try session(id: 1, day: "2026-10-23", start: "2026-10-23T08:30:00Z", end: "2026-10-23T09:15:00Z")
        let other = try session(id: 3, day: "2026-10-24", start: "2026-10-24T08:30:00Z", end: "2026-10-24T09:15:00Z")
        XCTAssertEqual(early.room, "A101")
        XCTAssertEqual(CourseScheduleCalculator.sessions(for: date("2026-10-23T12:00:00Z"), from: [late, other, early], calendar: calendar).map(\.id), [1, 2])
        XCTAssertTrue(CourseScheduleCalculator.sessions(for: date("2026-10-25T12:00:00Z"), from: [late, early], calendar: calendar).isEmpty)
    }

    func testTeachingWeekAndOddEvenManualRules() throws {
        let start = date("2026-09-01T00:00:00Z")
        XCTAssertNil(CourseScheduleCalculator.teachingWeek(on: date("2026-08-30T12:00:00Z"), termStart: start, calendar: calendar))
        XCTAssertEqual(CourseScheduleCalculator.teachingWeek(on: date("2026-09-01T12:00:00Z"), termStart: start, calendar: calendar), 1)
        XCTAssertEqual(CourseScheduleCalculator.teachingWeek(on: date("2026-09-08T12:00:00Z"), termStart: start, calendar: calendar), 2)
        let rule = ManualCourseRule(id: -1, termSourceID: "fall", name: "手动课程", weeks: [1, 3], weekday: 2,
                                    startPeriod: 1, endPeriod: 2, room: nil, teacher: nil, remoteID: nil)
        XCTAssertTrue(CourseScheduleCalculator.applies(rule, week: 1, weekday: 2))
        XCTAssertFalse(CourseScheduleCalculator.applies(rule, week: 2, weekday: 2))
        let term = TermInfo(id: 8, sourceTermID: "fall", displayName: "秋季", startDate: "2026-08-31", isCurrent: true)
        let periods = [PeriodInfo(periodNumber: 1, startTime: "08:30", endTime: "09:15"),
                       PeriodInfo(periodNumber: 2, startTime: "09:20", endTime: "10:05")]
        XCTAssertEqual(CourseScheduleCalculator.expandedManualCourses(on: date("2026-09-01T12:00:00Z"),
            rules: [rule], terms: [term], periods: periods, calendar: calendar).first?.source, "LOCAL")
        XCTAssertTrue(CourseScheduleCalculator.expandedManualCourses(on: date("2026-09-08T12:00:00Z"),
            rules: [rule], terms: [term], periods: periods, calendar: calendar).isEmpty)
    }

    func testActiveUpcomingCompletedAndCountdown() throws {
        let first = try session(id: 1, day: "2026-10-23", start: "2026-10-23T08:30:00Z", end: "2026-10-23T09:15:00Z")
        let second = try session(id: 2, day: "2026-10-23", start: "2026-10-23T10:25:00Z", end: "2026-10-23T11:10:00Z")
        XCTAssertEqual(CourseScheduleCalculator.active(in: [first, second], at: date("2026-10-23T08:45:00Z"))?.id, 1)
        XCTAssertEqual(CourseScheduleCalculator.upcoming(in: [first, second], at: date("2026-10-23T08:45:00Z"))?.id, 2)
        XCTAssertNil(CourseScheduleCalculator.active(in: [first, second], at: date("2026-10-23T12:00:00Z")))
        XCTAssertNil(CourseScheduleCalculator.upcoming(in: [first, second], at: date("2026-10-23T12:00:00Z")))
        XCTAssertEqual(CourseScheduleCalculator.countdown(until: date("2026-10-23T10:01:01Z"), from: date("2026-10-23T09:00:00Z")), "1 小时 2 分钟")
    }

    func testSwipeThresholdBounceAndClose() {
        var swipe = ScheduleSwipeState()
        XCTAssertEqual(swipe.reveal, 0)
        swipe.update(horizontal: -70, vertical: 2)
        swipe.end()
        XCTAssertEqual(swipe.reveal, 0)
        swipe.update(horizontal: -74, vertical: 2)
        swipe.end()
        XCTAssertEqual(swipe.reveal, 168)
        swipe.close()
        XCTAssertEqual(swipe.reveal, 0)
        swipe.update(horizontal: -40, vertical: -100)
        XCTAssertEqual(swipe.reveal, 0)
    }

    @MainActor
    func testCacheWallpaperRolloverAndClosingSwipeState() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sessionStore = TodayTestSessionStore()
        sessionStore.save(cookie: "session=fixture")
        let account = VerifiedAccountContext()
        try account.confirm(username: "tester", cookie: "session=fixture")
        let api = MockAPIClient()
        let repository = DiskCourseRepository(api: api, session: sessionStore, account: account, directory: folder)
        let wallpaper = WallpaperStore(session: sessionStore, directory: folder)
        let clock = MutableTodayClock(now: localDate(2026, 10, 23, 23, 59))
        let model = TodayViewModel(repository: repository, wallpaperStore: wallpaper, clock: clock)
        XCTAssertTrue(model.canEditSchedules)
        let schedule = CustomSchedule(id: -1, title: "提交作业", date: "2026-10-23", time: "09:00")
        try repository.saveSchedule(CustomSchedule(id: 0, title: schedule.title, date: schedule.date, time: schedule.time))
        let rule = ManualCourseRule(id: -1, termSourceID: "fall", name: "本地课程", weeks: [1, 3],
                                    weekday: 2, startPeriod: 1, endPeriod: 2,
                                    room: "A101", teacher: nil, remoteID: nil)
        try repository.saveManualRule(rule)
        try wallpaper.save(Data([1, 2, 3]))
        model.load()
        XCTAssertEqual(model.schedules, [schedule])
        XCTAssertEqual(model.wallpaperData, Data([1, 2, 3]))
        model.showActions(for: -1)
        XCTAssertEqual(model.openScheduleID, -1)
        model.closeActions() // Leaving the Today tab uses the same transition.
        XCTAssertNil(model.openScheduleID)
        model.showActions(for: -1)
        clock.now = localDate(2026, 10, 24, 0, 1)
        XCTAssertTrue(model.tick())
        XCTAssertNil(model.openScheduleID)
        XCTAssertTrue(model.schedules.isEmpty)
        let restored = TodayViewModel(repository: repository, wallpaperStore: wallpaper, clock: clock)
        restored.load()
        XCTAssertEqual(try repository.allLocalSchedules(), [schedule])
        XCTAssertEqual(try repository.cached()?.manualRules, [rule])
        XCTAssertEqual(restored.wallpaperData, Data([1, 2, 3]))
        try restored.removeWallpaper()
        XCTAssertNil(try wallpaper.load())
        XCTAssertNil(restored.wallpaperData)
        sessionStore.clear()
        account.clear()
        XCTAssertThrowsError(try repository.cached())
        XCTAssertNil(try wallpaper.load())
        XCTAssertThrowsError(try repository.allLocalSchedules())
    }

    @MainActor
    func testNetworkFailurePreservesCache() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sessionStore = TodayTestSessionStore()
        sessionStore.save(cookie: "session=fixture")
        let account = VerifiedAccountContext()
        try account.confirm(username: "tester", cookie: "session=fixture")
        let api = MockAPIClient()
        let repository = DiskCourseRepository(api: api, session: sessionStore, account: account, directory: folder)
        let wallpaper = WallpaperStore(session: sessionStore, directory: folder)
        let schedule = CustomSchedule(id: -1, title: "作业", date: "2026-10-23", time: "09:00")
        try repository.saveSchedule(CustomSchedule(id: 0, title: schedule.title, date: schedule.date, time: schedule.time))
        api.error = .connection
        let model = TodayViewModel(repository: repository, wallpaperStore: wallpaper,
                                   clock: MutableTodayClock(now: localDate(2026, 10, 23, 12, 0)))
        model.load()
        await model.refresh()
        XCTAssertEqual(model.schedules, [schedule])
        XCTAssertEqual(try repository.allLocalSchedules(), [schedule])
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testAnonymousAndUnverifiedCookieCannotReadOrMutateSchedules() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = TodayTestSessionStore()
        let account = VerifiedAccountContext()
        let store = LocalScheduleStore(session: session, account: account, directory: folder)
        let repository = DiskCourseRepository(api: MockAPIClient(), session: session, account: account,
                                              directory: folder, localStore: store)
        let model = TodayViewModel(repository: repository, wallpaperStore: WallpaperStore(session: session, directory: folder))
        let fixture = CustomSchedule(id: 0, title: "作业", date: "2026-10-23", time: "09:00")
        for cookie in ([nil, "session=unverified"] as [String?]) {
            if let cookie { session.save(cookie: cookie) } else { session.clear() }
            model.load(allowPrivateCache: false, allowLocalSchedules: false)
            XCTAssertFalse(model.canEditSchedules)
            XCTAssertTrue(model.schedules.isEmpty)
            XCTAssertThrowsError(try store.all())
            XCTAssertThrowsError(try store.save(fixture))
            XCTAssertThrowsError(try store.save(CustomSchedule(id: -1, title: "修改", date: fixture.date, time: fixture.time)))
            XCTAssertThrowsError(try store.delete(id: -1))
            XCTAssertThrowsError(try repository.cached())
            XCTAssertThrowsError(try model.saveSchedule(id: nil, title: fixture.title,
                                                       date: localDate(2026, 10, 23, 12, 0), time: fixture.time))
            XCTAssertThrowsError(try model.saveSchedule(id: -1, title: "修改",
                                                       date: localDate(2026, 10, 23, 12, 0), time: fixture.time))
            XCTAssertThrowsError(try model.deleteSchedule(id: -1))
        }
    }

    @MainActor
    func testVerifiedAccountCRUDRestartLogoutAndAccountSwitch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = TodayTestSessionStore()
        let account = VerifiedAccountContext()
        let store = LocalScheduleStore(session: session, account: account, directory: folder)
        session.save(cookie: "session=alice")
        try account.confirm(username: " Alice ", cookie: "session=alice")
        let model = TodayViewModel(repository: DiskCourseRepository(api: MockAPIClient(), session: session,
                              account: account, directory: folder, localStore: store),
                              wallpaperStore: WallpaperStore(session: session, directory: folder),
                              clock: MutableTodayClock(now: localDate(2026, 10, 23, 12, 0)))
        model.load()
        XCTAssertTrue(model.canEditSchedules)
        try model.saveSchedule(id: nil, title: "Alice 安排", date: localDate(2026, 10, 23, 12, 0), time: "08:30")
        XCTAssertEqual(model.schedules.map(\.title), ["Alice 安排"])
        try model.saveSchedule(id: -1, title: "Alice 修改", date: localDate(2026, 10, 23, 12, 0), time: "09:00")
        XCTAssertEqual(model.schedules.map(\.title), ["Alice 修改"])

        account.clear()
        XCTAssertThrowsError(try store.all())
        session.clear()
        model.authenticationDidChange(allowPrivateCache: false, allowLocalSchedules: false)
        XCTAssertTrue(model.schedules.isEmpty)
        session.save(cookie: "session=bob")
        XCTAssertThrowsError(try store.all())
        try account.confirm(username: "bob", cookie: "session=bob")
        XCTAssertTrue(try store.all().isEmpty)
        try store.save(CustomSchedule(id: 0, title: "Bob 安排", date: "2026-10-23", time: "10:00"))
        XCTAssertEqual(try store.all().map(\.title), ["Bob 安排"])
        session.save(cookie: "session=alice-new")
        XCTAssertThrowsError(try store.all())
        try account.confirm(username: "alice", cookie: "session=alice-new")
        XCTAssertEqual(try store.all().map(\.title), ["Alice 修改"])
        let restartedAccount = VerifiedAccountContext()
        let restarted = LocalScheduleStore(session: session, account: restartedAccount, directory: folder)
        XCTAssertThrowsError(try restarted.all())
        try restartedAccount.confirm(username: "alice", cookie: "session=alice-new")
        XCTAssertEqual(try restarted.all().map(\.title), ["Alice 修改"])
        try restarted.delete(id: -1)
        XCTAssertTrue(try restarted.all().isEmpty)
        session.save(cookie: "session=bob")
        try restartedAccount.confirm(username: "bob", cookie: "session=bob")
        XCTAssertEqual(try restarted.all().map(\.title), ["Bob 安排"])
    }

    @MainActor
    func testLegacyGuestAndSessionRecordsRemainOnDiskWithoutMigration() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = TodayTestSessionStore()
        let account = VerifiedAccountContext()
        let store = LocalScheduleStore(session: session, account: account, directory: folder)
        let digest = SHA256.hash(data: Data(APIConfiguration.development.baseURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let file = folder.appendingPathComponent("local_schedules_\(digest).json")
        let legacy = #"{"accounts":{"guest:old":{"records":[{"id":-1,"title":"旧访客","scheduled_date":"2026-10-23","scheduled_time":"09:00"}],"deletedRemoteIDs":[],"serverImported":false},"session:old":{"records":[{"id":-1,"title":"旧临时会话","scheduled_date":"2026-10-23","scheduled_time":"10:00"}],"deletedRemoteIDs":[],"serverImported":false}}}"#
        try Data(legacy.utf8).write(to: file)
        session.save(cookie: "session=alice")
        try account.confirm(username: "alice", cookie: "session=alice")
        XCTAssertTrue(try store.all().isEmpty)
        try store.save(CustomSchedule(id: 0, title: "Alice 新建", date: "2026-10-23", time: "11:00"))
        let persisted = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(persisted.contains("guest:old"))
        XCTAssertTrue(persisted.contains("session:old"))
        XCTAssertEqual(try store.all().map(\.title), ["Alice 新建"])
    }
}

private final class TodayTestSessionStore: SessionStore {
    private(set) var cookie: String?
    func save(cookie: String) { self.cookie = cookie }
    func clear() { cookie = nil }
}

private final class MutableTodayClock: TodayClock {
    var now: Date
    init(now: Date) { self.now = now }
}
