import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import HandHelperNative

final class TimetableViewTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    private var fixedDate: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12))!
    }

    private func fixture() -> CourseSnapshot {
        var snapshot = CourseSnapshot.empty
        snapshot.terms = [TermInfo(id: 1, sourceTermID: "a", displayName: "秋季",
                                   startDate: "2026-08-31", isCurrent: true),
                          TermInfo(id: 2, sourceTermID: "b", displayName: "春季",
                                   startDate: "2026-09-07", isCurrent: false)]
        snapshot.periods = [PeriodInfo(periodNumber: 1, startTime: "08:00", endTime: "08:45"),
                            PeriodInfo(periodNumber: 2, startTime: "08:50", endTime: "09:35")]
        snapshot.calendarSessions = [CourseSession(id: 1, name: "数学", date: "2026-08-31",
            startDateTime: "2026-08-31T08:00:00", endDateTime: "2026-08-31T09:35:00",
            room: "A101", teacher: "教师", weekExpression: "1周", source: "IMPORTED",
            manualCourseID: nil, termID: 1, weekday: 1, startPeriod: 1, endPeriod: 2)]
        return snapshot
    }

    @MainActor
    private func setup() async throws -> (AppState, TimetableModelRepository, TimetableViewModel) {
        let session = TimetableModelSession()
        session.save(cookie: "session=alice")
        let preferences = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let state = AppState(api: TimetableModelAPI(), sessionStore: session,
                             authentication: TimetableModelAuth(), preferences: preferences)
        let repository = TimetableModelRepository()
        repository.stored = fixture()
        let model = TimetableViewModel(state: state, repository: repository,
                                       calendar: calendar, now: { self.fixedDate })
        await state.restoreSession()
        state.selectedTab = .timetable
        return (state, repository, model)
    }

    @MainActor
    func testCachedWeekAndTermSwitchDoNotRequestNetwork() async throws {
        let (_, repository, model) = try await setup()
        model.loadCached()
        XCTAssertEqual(model.selectedTermID, 1)
        XCTAssertEqual(model.selectedWeek, 1)
        XCTAssertEqual(model.projection?.dates.count, 7)
        XCTAssertEqual(model.projection?.placements.map(\.course.id), [1])
        model.moveWeek(1)
        XCTAssertEqual(model.selectedWeek, 2)
        XCTAssertTrue(model.projection?.placements.isEmpty == true)
        model.selectTerm(2)
        XCTAssertEqual(model.selectedTermID, 2)
        XCTAssertEqual(model.selectedWeek, 1)
        model.selectTerm(1)
        XCTAssertEqual(model.projection?.placements.count, 1)
        XCTAssertEqual(repository.refreshCount, 0)
    }

    @MainActor
    func testLocalManualSaveReprojectsAndPublishesAccountScopedChangeWithoutNetwork() async throws {
        let (state, repository, model) = try await setup()
        model.loadCached()
        let cell = TimetableEmptyCellSelection(owner: try state.requireCurrentAccount(
            revision: state.authenticationRevision), authenticationRevision: state.authenticationRevision,
            termID: 1, week: 1, snapshotRevision: model.snapshotRevision,
            weekday: 3, periodNumber: 2)
        var draft = ManualCourseDraft(cell: cell)
        draft.name = "本地课程"
        try model.addManualCourse(draft, from: cell)
        XCTAssertEqual(repository.createCount, 1)
        XCTAssertEqual(repository.refreshCount, 0)
        XCTAssertTrue(model.projection?.placements.contains { $0.course.name == "本地课程" } == true)
        XCTAssertEqual(state.localManualCourseChange?.owner, cell.owner)
        XCTAssertEqual(state.localManualCourseChange?.authenticationRevision, cell.authenticationRevision)
        XCTAssertNil(state.courseDataInvalidation)
        XCTAssertThrowsError(try model.addManualCourse(draft, from: cell),
                             "旧快照上的重复提交不得再次写入")
        XCTAssertEqual(repository.createCount, 1)
    }

    @MainActor
    func testManualSaveRejectsStaleTermAndAuthentication() async throws {
        let (state, repository, model) = try await setup()
        model.loadCached()
        let cell = TimetableEmptyCellSelection(owner: try state.requireCurrentAccount(
            revision: state.authenticationRevision), authenticationRevision: state.authenticationRevision,
            termID: 1, week: 1, snapshotRevision: model.snapshotRevision,
            weekday: 3, periodNumber: 2)
        var draft = ManualCourseDraft(cell: cell)
        draft.name = "旧表单"
        model.selectTerm(2)
        XCTAssertThrowsError(try model.addManualCourse(draft, from: cell))
        model.selectTerm(1)
        await state.logout()
        XCTAssertNil(state.localManualCourseChange)
        XCTAssertThrowsError(try model.addManualCourse(draft, from: cell))
        XCTAssertEqual(repository.createCount, 0)
    }

    @MainActor
    func testOnlyLocalRuleCanBeEditedOrDeletedWithoutNetwork() async throws {
        let (state, repository, model) = try await setup()
        model.loadCached()
        let remote = try XCTUnwrap(model.projection?.placements.first?.course)
        let remoteContext = TimetableDetailContext(authenticationRevision: state.authenticationRevision,
            termID: 1, week: 1, snapshotRevision: model.snapshotRevision,
            courseID: remote.id, placementIndex: 0)
        XCTAssertNil(model.editableManualCourse(for: remote, context: remoteContext))

        let owner = try state.requireCurrentAccount(revision: state.authenticationRevision)
        let cell = TimetableEmptyCellSelection(owner: owner, authenticationRevision: state.authenticationRevision,
            termID: 1, week: 1, snapshotRevision: model.snapshotRevision, weekday: 3, periodNumber: 1)
        var draft = ManualCourseDraft(cell: cell)
        draft.name = "原课程"
        try model.addManualCourse(draft, from: cell)
        let local = try XCTUnwrap(model.projection?.placements.first(where: { $0.course.source == "LOCAL" })?.course)
        let context = TimetableDetailContext(authenticationRevision: state.authenticationRevision,
            termID: 1, week: 1, snapshotRevision: model.snapshotRevision,
            courseID: local.id, placementIndex: 0)
        let identity = try XCTUnwrap(model.editableManualCourse(for: local, context: context))
        XCTAssertEqual(identity.owner, owner)
        let request = TimetableManualCourseActionRequest(action: .edit, identity: identity, context: context)
        let rule = try XCTUnwrap(model.manualRule(for: request))
        var edit = ManualCourseDraft(rule: rule)
        edit.name = "修改后"
        edit.weekday = 4
        edit.startPeriod = 2
        edit.endPeriod = 2
        edit.weeks = [2]
        try model.updateManualCourse(edit, for: request)
        XCTAssertEqual(repository.updateCount, 1)
        XCTAssertEqual(repository.stored?.manualRules.count, 1)
        XCTAssertEqual(repository.stored?.manualRules.first?.id, rule.id)
        XCTAssertFalse(model.projection?.placements.contains { $0.course.source == "LOCAL" } == true)
        XCTAssertThrowsError(try model.updateManualCourse(edit, for: request),
                             "旧快照操作不得重复提交")
        model.selectWeek(2)
        let moved = try XCTUnwrap(model.projection?.placements.first(where: { $0.course.source == "LOCAL" })?.course)
        let movedContext = TimetableDetailContext(authenticationRevision: state.authenticationRevision,
            termID: 1, week: 2, snapshotRevision: model.snapshotRevision,
            courseID: moved.id, placementIndex: 0)
        let movedIdentity = try XCTUnwrap(model.editableManualCourse(for: moved, context: movedContext))
        let delete = TimetableManualCourseActionRequest(action: .delete, identity: movedIdentity,
                                                         context: movedContext)
        try model.deleteManualCourse(for: delete)
        XCTAssertEqual(repository.deleteManualCount, 1)
        XCTAssertTrue(repository.stored?.manualRules.isEmpty == true)
        XCTAssertFalse(model.projection?.placements.contains { $0.course.source == "LOCAL" } == true)
        XCTAssertThrowsError(try model.deleteManualCourse(for: delete))
        XCTAssertEqual(repository.refreshCount, 0)
        XCTAssertEqual(state.localManualCourseChange?.owner, owner)
    }

    @MainActor
    func testManualEditRejectsMissingRuleTermChangeAndLogout() async throws {
        let (state, repository, model) = try await setup()
        var stored = try XCTUnwrap(repository.stored)
        stored.manualRules = [ManualCourseRule(id: -4, termSourceID: "a", name: "手动课",
            weeks: [1], weekday: 3, startPeriod: 1, endPeriod: 1,
            room: nil, teacher: nil, remoteID: nil)]
        repository.stored = stored
        model.loadCached()
        let local = try XCTUnwrap(model.projection?.placements.first(where: { $0.course.source == "LOCAL" })?.course)
        let context = TimetableDetailContext(authenticationRevision: state.authenticationRevision,
            termID: 1, week: 1, snapshotRevision: model.snapshotRevision,
            courseID: local.id, placementIndex: 0)
        let identity = try XCTUnwrap(model.editableManualCourse(for: local, context: context))
        let request = TimetableManualCourseActionRequest(action: .edit, identity: identity, context: context)
        let draft = ManualCourseDraft(rule: try XCTUnwrap(model.manualRule(for: request)))
        model.selectTerm(2)
        XCTAssertThrowsError(try model.updateManualCourse(draft, for: request))
        model.selectTerm(1)
        stored.manualRules = []
        repository.stored = stored
        model.loadCached()
        XCTAssertThrowsError(try model.updateManualCourse(draft, for: request))
        await state.logout()
        XCTAssertThrowsError(try model.deleteManualCourse(for: request))
        XCTAssertEqual(repository.updateCount, 0)
        XCTAssertEqual(repository.deleteManualCount, 0)
    }

    func testPageDelegateCommitsOnlyCompletedAdjacentTransition() {
        XCTAssertEqual(TimetablePageTransition.committedWeek(from: 2, to: 3, completed: true), 3)
        XCTAssertEqual(TimetablePageTransition.committedWeek(from: 2, to: 1, completed: true), 1)
        XCTAssertNil(TimetablePageTransition.committedWeek(from: 2, to: 3, completed: false))
        XCTAssertNil(TimetablePageTransition.committedWeek(from: 2, to: 4, completed: true))
        XCTAssertNil(TimetablePageTransition.committedWeek(from: nil, to: 2, completed: true))
    }

    @MainActor
    func testUIKitPagerPrefetchesNeighbourAndCommitsOnlyCompletedSwipe() async throws {
        let (state, repository, model) = try await setup()
        model.loadCached()
        let pager = TimetableWeekPager(model: model,
                                       authenticationRevision: state.authenticationRevision,
                                       renderRevision: 0, wallpaperVisible: false,
                                       layoutScale: 1,
                                       reduceMotion: false) { projection in
            Text("第 \(projection.week) 周")
        }
        let coordinator = pager.makeCoordinator()
        let controller = UIPageViewController(transitionStyle: .scroll,
                                              navigationOrientation: .horizontal)
        controller.dataSource = coordinator
        controller.delegate = coordinator
        coordinator.install(in: controller)
        let first = try XCTUnwrap(controller.viewControllers?.first)
        let second = try XCTUnwrap(coordinator.pageViewController(controller, viewControllerAfter: first))
        XCTAssertNil(coordinator.pageViewController(controller, viewControllerBefore: first))
        XCTAssertEqual(model.selectedWeek, 1, "预取不能改变顶部周次")

        coordinator.pageViewController(controller, willTransitionTo: [second])
        coordinator.pageViewController(controller, didFinishAnimating: true,
                                       previousViewControllers: [first], transitionCompleted: false)
        XCTAssertEqual(model.selectedWeek, 1, "回弹不能提交周次")

        coordinator.pageViewController(controller, willTransitionTo: [second])
        controller.setViewControllers([second], direction: .forward, animated: false)
        coordinator.pageViewController(controller, didFinishAnimating: true,
                                       previousViewControllers: [first], transitionCompleted: true)
        XCTAssertEqual(model.selectedWeek, 2)
        XCTAssertEqual(model.projection?.week, 2)
        XCTAssertEqual(repository.refreshCount, 0)
    }

    @MainActor
    func testAdjacentPagesUseSameSnapshotAsButtonsAndRespectFirstWeek() async throws {
        let (_, repository, model) = try await setup()
        model.loadCached()
        let firstWeekDates = try XCTUnwrap(model.projection?.dates)
        XCTAssertNil(model.projection(for: 0))
        XCTAssertEqual(model.projection(for: 2)?.dates.count, 7)
        XCTAssertEqual(model.selectedWeek, 1, "预取相邻周不能提前提交周次")
        model.moveWeek(-1)
        XCTAssertEqual(model.selectedWeek, 1)
        XCTAssertEqual(model.projection?.dates, firstWeekDates)

        let next = try XCTUnwrap(TimetablePageTransition.committedWeek(from: 1, to: 2, completed: true))
        model.selectWeek(next)
        let pageDates = try XCTUnwrap(model.projection?.dates)
        XCTAssertEqual(model.selectedWeek, 2)
        model.moveWeek(-1)
        model.moveWeek(1)
        XCTAssertEqual(model.selectedWeek, 2)
        XCTAssertEqual(model.projection?.dates, pageDates)
        XCTAssertEqual(repository.refreshCount, 0)
    }

    @MainActor
    func testRapidProgrammaticSelectionAndTermSwitchReprojectWithoutRequests() async throws {
        let (_, repository, model) = try await setup()
        model.loadCached()
        for week in [2, 3, 4, 2, 1] { model.selectWeek(week) }
        XCTAssertEqual(model.selectedWeek, 1)
        XCTAssertEqual(model.projection?.placements.map(\.course.id), [1])
        model.selectTerm(2)
        XCTAssertEqual(model.selectedTermID, 2)
        XCTAssertEqual(model.projection(for: 1)?.term.id, 2)
        XCTAssertEqual(repository.refreshCount, 0)
    }

    @MainActor
    func testStrictRefreshReprojectsAndAcknowledgesOnlyAfterDurableSuccess() async throws {
        let (state, repository, model) = try await setup()
        model.loadCached()
        let owner = try state.requireCurrentAccount(revision: state.authenticationRevision)
        try state.invalidateCourses(for: owner, authenticationRevision: state.authenticationRevision)
        let marker = try XCTUnwrap(state.courseDataInvalidation)
        repository.refreshError = APIError.invalidResponse
        await model.updateIfNeeded()
        XCTAssertEqual(repository.refreshCount, 1)
        XCTAssertNil(state.completedCourseRefresh)
        XCTAssertEqual(model.projection?.placements.map(\.course.id), [1])
        repository.refreshError = nil
        var updated = fixture()
        updated.calendarSessions = []
        repository.fresh = updated
        await model.updateIfNeeded()
        XCTAssertEqual(repository.refreshCount, 2)
        XCTAssertEqual(state.completedCourseRefresh, marker)
        XCTAssertTrue(model.projection?.placements.isEmpty == true)
        await model.updateIfNeeded()
        XCTAssertEqual(repository.refreshCount, 2)
    }

    @MainActor
    func testOtherTabReusesCompletedSnapshotWithoutDuplicateRequest() async throws {
        let (state, repository, model) = try await setup()
        let owner = try state.requireCurrentAccount(revision: state.authenticationRevision)
        try state.invalidateCourses(for: owner, authenticationRevision: state.authenticationRevision)
        let marker = try XCTUnwrap(state.courseDataInvalidation)
        state.acknowledgeCourseRefresh(marker)
        await model.updateIfNeeded()
        XCTAssertEqual(model.projection?.placements.count, 1)
        XCTAssertEqual(repository.refreshCount, 0)
    }

    @MainActor
    func testUnverifiedSessionAndLogoutHideSnapshot() async throws {
        let session = TimetableModelSession()
        session.save(cookie: "session=alice")
        let state = AppState(api: TimetableModelAPI(), sessionStore: session,
                             authentication: TimetableModelAuth(),
                             preferences: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let repository = TimetableModelRepository()
        repository.stored = fixture()
        let model = TimetableViewModel(state: state, repository: repository,
                                       calendar: calendar, now: { self.fixedDate })
        model.loadCached()
        XCTAssertNil(model.snapshot)
        await state.restoreSession()
        model.loadCached()
        XCTAssertNotNil(model.projection)
        await state.logout()
        XCTAssertNil(model.projection(for: 1), "登出后即使内存快照尚未清空也不得构建周页面")
        model.loadCached()
        XCTAssertNil(model.snapshot)
        XCTAssertNil(model.projection)
        XCTAssertEqual(repository.refreshCount, 0)
    }

    @MainActor
    func testAccountSwitchCannotKeepOldProjection() async throws {
        let (state, repository, model) = try await setup()
        model.loadCached()
        XCTAssertEqual(model.projection?.placements.first?.course.name, "数学")
        await state.logout()
        model.clear()
        repository.stored = nil
        await state.login(username: "bob", password: "fixture")
        model.loadCached()
        XCTAssertNil(model.projection)
        XCTAssertNil(model.snapshot)
    }

    @MainActor
    func testEmptyTermsAndUnplacedCoursesStayDiscoverable() async throws {
        let (_, repository, model) = try await setup()
        var empty = CourseSnapshot.empty
        repository.stored = empty
        model.loadCached()
        XCTAssertTrue(model.terms.isEmpty)
        XCTAssertNil(model.projection)
        empty = fixture()
        let original = empty.calendarSessions[0]
        empty.calendarSessions = [CourseSession(id: original.id, name: original.name, date: original.date,
            startDateTime: original.startDateTime, endDateTime: original.endDateTime,
            room: original.room, teacher: original.teacher, weekExpression: original.weekExpression,
            source: original.source, manualCourseID: original.manualCourseID, termID: original.termID,
            weekday: original.weekday, startPeriod: 99, endPeriod: 2)]
        repository.stored = empty
        model.loadCached()
        XCTAssertEqual(model.projection?.unplaced.count, 1)
        XCTAssertTrue(model.projection?.placements.isEmpty == true)
    }

    func testGridSharesCoordinatesForSevenDaysSpansAndLanes() {
        let wide = TimetableGridMetrics(viewportWidth: 900, rowCount: 12)
        let narrow = TimetableGridMetrics(viewportWidth: 320, rowCount: 12, dynamicScale: 1.5)
        let course = fixture().calendarSessions[0]
        let first = WeeklyCoursePlacement(course: course, weekday: 1, startPeriod: 1, endPeriod: 2,
            startRow: 0, rowSpan: 2, conflictGroup: 0, laneIndex: 0, laneCount: 2)
        let second = WeeklyCoursePlacement(course: course, weekday: 1, startPeriod: 1, endPeriod: 2,
            startRow: 0, rowSpan: 2, conflictGroup: 0, laneIndex: 1, laneCount: 2)
        let sunday = WeeklyCoursePlacement(course: course, weekday: 7, startPeriod: 2, endPeriod: 2,
            startRow: 1, rowSpan: 1, conflictGroup: 1, laneIndex: 0, laneCount: 1)
        let crowded = WeeklyCoursePlacement(course: course, weekday: 1, startPeriod: 1, endPeriod: 2,
            startRow: 0, rowSpan: 2, conflictGroup: 2, laneIndex: 0, laneCount: 3)
        XCTAssertEqual(wide.frame(for: first).height, wide.rowHeight * 2)
        XCTAssertEqual(wide.frame(for: first).maxX, wide.frame(for: second).minX)
        XCTAssertEqual(wide.frame(for: sunday).maxX, wide.width)
        XCTAssertEqual(wide.frame(for: sunday).minY, wide.rowHeight)
        XCTAssertFalse(wide.shouldSummarize(first))
        XCTAssertTrue(narrow.shouldSummarize(crowded))
        XCTAssertFalse(narrow.shouldSummarize(sunday))
        XCTAssertEqual(narrow.width, 320)
    }

    func testSevenColumnsFitCommonPhoneWidthsAndAlignEveryLayer() {
        let course = fixture().calendarSessions[0]
        for width in [CGFloat(320), 375, 393, 430] {
            let grid = TimetableGridMetrics(viewportWidth: width, rowCount: 13, dynamicScale: 1.7)
            XCTAssertEqual(grid.width, width)
            XCTAssertEqual(grid.dayOrigin(1), grid.railWidth)
            XCTAssertEqual(grid.dayOrigin(7) + grid.dayWidth(7), width, accuracy: 0.0001)
            for day in 1..<7 {
                XCTAssertEqual(grid.dayOrigin(day) + grid.dayWidth(day), grid.dayOrigin(day + 1), accuracy: 0.0001)
            }
            let sunday = WeeklyCoursePlacement(course: course, weekday: 7, startPeriod: 1,
                endPeriod: 2, startRow: 0, rowSpan: 2, conflictGroup: 0, laneIndex: 0, laneCount: 1)
            XCTAssertEqual(grid.frame(for: sunday).maxX, width, accuracy: 0.0001)
            XCTAssertEqual(grid.frame(for: sunday).height, grid.rowHeight * 2)
            XCTAssertFalse(grid.shouldSummarize(sunday))
        }
    }

    func testOverlapSummarizesOnlyMultipleCoursesAndCardContentHasBoundedLines() {
        let course = fixture().calendarSessions[0]
        let grid = TimetableGridMetrics(viewportWidth: 375, rowCount: 13)
        let solo = WeeklyCoursePlacement(course: course, weekday: 1, startPeriod: 1,
            endPeriod: 1, startRow: 0, rowSpan: 1, conflictGroup: 0, laneIndex: 0, laneCount: 1)
        let overlap = WeeklyCoursePlacement(course: course, weekday: 1, startPeriod: 1,
            endPeriod: 1, startRow: 0, rowSpan: 1, conflictGroup: 1, laneIndex: 0, laneCount: 2)
        XCTAssertFalse(grid.shouldSummarize(solo))
        XCTAssertTrue(grid.shouldSummarize(overlap))
        let short = TimetableCardContentPolicy(rowSpan: 1)
        let medium = TimetableCardContentPolicy(rowSpan: 2)
        let long = TimetableCardContentPolicy(rowSpan: 3)
        XCTAssertEqual(short.titleLines, 3)
        XCTAssertEqual(short.roomLines, 1)
        XCTAssertTrue(short.showsRoom)
        XCTAssertFalse(short.showsTeacher)
        XCTAssertEqual(medium.titleLines, 6)
        XCTAssertEqual(medium.roomLines, 2)
        XCTAssertTrue(medium.showsTeacher)
        XCTAssertEqual(long.titleLines, 6)
        XCTAssertEqual(long.roomLines, 2)
        XCTAssertTrue(long.showsTeacher)
    }

    func testDateLabelsHandleMonthAndYearTransitions() {
        XCTAssertEqual(TimetableDateLabel.month("2026-12-28"), "12月")
        XCTAssertEqual(TimetableDateLabel.day("2026-12-31", previous: "2026-12-30"), "31")
        XCTAssertEqual(TimetableDateLabel.day("2027-01-01", previous: "2026-12-31"), "1/1")
        XCTAssertEqual(TimetableDateLabel.day("2027-01-02", previous: "2027-01-01"), "2")
    }

    func testEveryTeachingPeriodHasSevenAlignedLogicalCellsAndSingleGridBoundaries() {
        for width in [CGFloat(320), 375, 393, 430] {
            let grid = TimetableGridMetrics(viewportWidth: width, rowCount: 11)
            XCTAssertEqual(grid.verticalBoundaries.count, 9)
            XCTAssertEqual(grid.horizontalBoundaries.count, 12)
            XCTAssertEqual(grid.verticalBoundaries.first, 0)
            XCTAssertEqual(grid.verticalBoundaries.last, width)
            XCTAssertEqual(grid.horizontalBoundaries.first, 0)
            XCTAssertEqual(grid.horizontalBoundaries.last, grid.bodyHeight)
            for row in 0..<11 {
                let cells = (1...7).map { grid.cellFrame(weekday: $0, row: row) }
                XCTAssertTrue(cells.allSatisfy { $0.minY == grid.rowOrigin(row) && $0.maxY == grid.rowOrigin(row + 1) })
                XCTAssertEqual(cells.first?.minX, grid.railWidth)
                XCTAssertEqual(cells.last?.maxX, width)
                for day in 0..<6 { XCTAssertEqual(cells[day].maxX, cells[day + 1].minX, accuracy: 0.0001) }
            }
        }
    }

    func testConsecutiveCourseSpansHaveNoInsertedBreakRows() {
        let course = fixture().calendarSessions[0]
        let grid = TimetableGridMetrics(viewportWidth: 375, rowCount: 11)
        let spans = [(0, 2), (2, 2), (4, 3)]
        for (start, span) in spans {
            let placement = WeeklyCoursePlacement(course: course, weekday: 3,
                startPeriod: start + 1, endPeriod: start + span,
                startRow: start, rowSpan: span, conflictGroup: start,
                laneIndex: 0, laneCount: 1)
            let frame = grid.frame(for: placement)
            XCTAssertEqual(frame.minY, grid.rowOrigin(start))
            XCTAssertEqual(frame.maxY, grid.rowOrigin(start + span))
            XCTAssertEqual(frame.height, CGFloat(span) * grid.rowHeight)
        }
        XCTAssertEqual(grid.rowOrigin(2), grid.rowOrigin(0) + 2 * grid.rowHeight)
        XCTAssertEqual(grid.rowOrigin(4), grid.rowOrigin(2) + 2 * grid.rowHeight)
    }

    func testConflictingLanesSharePeriodCoordinatesWithoutDroppingSingleCourse() {
        let course = fixture().calendarSessions[0]
        let grid = TimetableGridMetrics(viewportWidth: 375, rowCount: 11)
        let first = WeeklyCoursePlacement(course: course, weekday: 7, startPeriod: 3,
            endPeriod: 4, startRow: 2, rowSpan: 2, conflictGroup: 1, laneIndex: 0, laneCount: 2)
        let second = WeeklyCoursePlacement(course: course, weekday: 7, startPeriod: 3,
            endPeriod: 4, startRow: 2, rowSpan: 2, conflictGroup: 1, laneIndex: 1, laneCount: 2)
        let solo = WeeklyCoursePlacement(course: course, weekday: 7, startPeriod: 3,
            endPeriod: 4, startRow: 2, rowSpan: 2, conflictGroup: 2, laneIndex: 0, laneCount: 1)
        XCTAssertEqual(grid.frame(for: first).maxX, grid.frame(for: second).minX, accuracy: 0.0001)
        XCTAssertEqual(grid.frame(for: first).minY, grid.cellFrame(weekday: 7, row: 2).minY)
        XCTAssertEqual(grid.frame(for: second).maxY, grid.cellFrame(weekday: 7, row: 3).maxY)
        XCTAssertTrue(grid.shouldSummarize(first))
        XCTAssertFalse(grid.shouldSummarize(solo))
    }

    func testMissingOrInvalidPeriodTimesUseSafeLabels() {
        XCTAssertEqual(TimetablePeriodLabel.safeTime("08:00"), "08:00")
        XCTAssertEqual(TimetablePeriodLabel.safeTime(""), "—")
        XCTAssertEqual(TimetablePeriodLabel.safeTime("25:70"), "—")
        XCTAssertEqual(TimetablePeriodLabel.safeTime("8:00"), "—")
    }
}

private final class TimetableModelSession: SessionStore {
    private(set) var cookie: String?
    func save(cookie: String) { self.cookie = cookie }
    @discardableResult func clear() -> Bool { cookie = nil; return true }
}

private final class TimetableModelAuth: AuthenticationClientProtocol {
    func login(username: String, password: String) async throws -> (cookie: String, identity: VerifiedIdentity) {
        ("session=\(username)", VerifiedIdentity(authenticated: true, username: username))
    }
    func verify(cookie: String) async throws -> VerifiedIdentity {
        VerifiedIdentity(authenticated: true, username: "alice")
    }
    func logout(cookie: String) async throws {}
}

private final class TimetableModelAPI: APIClientProtocol {
    func request<Value: Decodable>(_ method: String, path: String, body: Data?,
                                   preserveSessionOnPasswordError: Bool) async throws -> Value {
        throw APIError.invalidResponse
    }
}

@MainActor
private final class TimetableModelRepository: CourseRepository {
    var stored: CourseSnapshot?
    var fresh: CourseSnapshot?
    var refreshError: Error?
    var refreshCount = 0
    var createCount = 0
    var updateCount = 0
    var deleteManualCount = 0
    var sessionCookie: String? { "session=alice" }
    var canEditSchedules: Bool { false }
    func cached() throws -> CourseSnapshot? { stored }
    func refresh(on date: Date) async throws -> CourseSnapshot { throw APIError.invalidResponse }
    func refreshStrict(on date: Date, isCurrent: @escaping @MainActor () -> Bool) async throws -> CourseSnapshot {
        refreshCount += 1
        if let refreshError { throw refreshError }
        guard isCurrent(), let fresh else { throw APIError.invalidResponse }
        stored = fresh
        return fresh
    }
    func localSchedules(on date: Date) throws -> [CustomSchedule] { [] }
    func allLocalSchedules() throws -> [CustomSchedule] { [] }
    func saveSchedule(_ schedule: CustomSchedule) throws {}
    func deleteSchedule(id: Int) throws {}
    func saveManualRule(_ rule: ManualCourseRule) throws {}
    func createManualRule(termID: Int, name: String, weeks: [Int], weekday: Int,
                          startPeriod: Int, endPeriod: Int, room: String?, teacher: String?) throws -> ManualCourseRule {
        createCount += 1
        guard var stored, let term = stored.terms.first(where: { $0.id == termID }) else {
            throw APIError.invalidResponse
        }
        let rule = ManualCourseRule(id: -createCount, termSourceID: term.sourceTermID,
            name: name, weeks: weeks, weekday: weekday, startPeriod: startPeriod,
            endPeriod: endPeriod, room: room, teacher: teacher, remoteID: nil)
        stored.manualRules.append(rule)
        self.stored = stored
        return rule
    }
    func updateManualRule(id: Int, termID: Int, name: String, weeks: [Int], weekday: Int,
                          startPeriod: Int, endPeriod: Int, room: String?, teacher: String?) throws -> ManualCourseRule {
        guard var stored, let index = stored.manualRules.firstIndex(where: { $0.id == id }),
              stored.terms.contains(where: { $0.id == termID }) else {
            throw ManualCoursePersistenceError.ruleNotFound
        }
        updateCount += 1
        let old = stored.manualRules[index]
        let updated = ManualCourseRule(id: old.id, termSourceID: old.termSourceID,
            name: name, weeks: weeks, weekday: weekday, startPeriod: startPeriod,
            endPeriod: endPeriod, room: room, teacher: teacher, remoteID: old.remoteID)
        stored.manualRules[index] = updated
        self.stored = stored
        return updated
    }
    func deleteManualRule(id: Int, termID: Int) throws {
        guard var stored, let index = stored.manualRules.firstIndex(where: { $0.id == id }),
              stored.terms.contains(where: { $0.id == termID }) else {
            throw ManualCoursePersistenceError.ruleNotFound
        }
        deleteManualCount += 1
        stored.manualRules.remove(at: index)
        self.stored = stored
    }
    func saveProfile(_ profile: TodayProfile) throws {}
}
