import XCTest
@testable import HandHelperNative

final class ManualCourseEditorTests: XCTestCase {
    private var cell: TimetableEmptyCellSelection {
        TimetableEmptyCellSelection(owner: "user:alice", authenticationRevision: 4,
            termID: 8, week: 3, snapshotRevision: 2, weekday: 5, periodNumber: 7)
    }

    func testDraftUsesSelectedWeekWeekdayAndActualPeriodNumber() {
        let draft = ManualCourseDraft(cell: cell)
        XCTAssertEqual(draft.weeks, [3])
        XCTAssertEqual(draft.weekday, 5)
        XCTAssertEqual(draft.startPeriod, 7)
        XCTAssertEqual(draft.endPeriod, 7)
    }

    func testDraftValidatesNameWeeksAndRealPeriods() {
        var draft = ManualCourseDraft(cell: cell)
        let available: Set<Int> = [1, 3, 7]
        XCTAssertNotNil(draft.validationMessage(availablePeriods: available))
        draft.name = "数据分析"
        XCTAssertNil(draft.validationMessage(availablePeriods: available))
        draft.weeks = []
        XCTAssertNotNil(draft.validationMessage(availablePeriods: available))
        draft.weeks = [1, 3, 19]
        XCTAssertNil(draft.validationMessage(availablePeriods: available))
        draft.weeks = [21]
        XCTAssertNotNil(draft.validationMessage(availablePeriods: available))
        draft.weeks = [2, 4, 20]
        XCTAssertNil(draft.validationMessage(availablePeriods: available))
        draft.startPeriod = 2
        XCTAssertNotNil(draft.validationMessage(availablePeriods: available))
        draft.startPeriod = 7
        draft.endPeriod = 3
        XCTAssertNotNil(draft.validationMessage(availablePeriods: available))
    }

    @MainActor
    func testSelectionMovesAndClearsWithoutLeakingToAnotherWeek() {
        let coordinator = TimetableEmptyCellSelectionCoordinator()
        coordinator.select(cell)
        XCTAssertEqual(coordinator.selected, cell)
        let otherWeek = TimetableEmptyCellSelection(owner: cell.owner,
            authenticationRevision: cell.authenticationRevision, termID: cell.termID,
            week: 4, snapshotRevision: cell.snapshotRevision, weekday: 5, periodNumber: 7)
        XCTAssertNotEqual(coordinator.selected, otherWeek)
        coordinator.select(otherWeek)
        XCTAssertEqual(coordinator.selected, otherWeek)
        coordinator.clear()
        XCTAssertNil(coordinator.selected)
    }
}
