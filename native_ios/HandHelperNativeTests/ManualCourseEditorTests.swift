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

    @MainActor
    private func context(termID: Int? = 8, week: Int = 3, snapshotRevision: Int = 2,
                         owner: String? = "user:alice", pagerBusy: Bool = false,
                         tabActive: Bool = true, detailPresenting: Bool = false)
        -> TimetableEmptyCellSelectionCoordinator.OpeningContext {
        .init(tabActive: tabActive, detailPresenting: detailPresenting, pagerBusy: pagerBusy,
              termID: termID, week: week, snapshotRevision: snapshotRevision,
              verifiedOwner: owner)
    }

    @MainActor
    func testPlusOpensOneRouteAndClearsSelectedPlus() {
        let coordinator = TimetableEmptyCellSelectionCoordinator()
        coordinator.select(cell)
        let operationID = coordinator.selectionOperationID
        XCTAssertNil(coordinator.open(cell, context: context(), tappedAt: 10))
        XCTAssertNotNil(coordinator.route)
        XCTAssertEqual(coordinator.route?.cell, cell)
        XCTAssertEqual(coordinator.route?.operationID, operationID)
        XCTAssertNil(coordinator.selected)
        coordinator.clear(reason: "unrelated_page_update")
        XCTAssertNotNil(coordinator.route)
        XCTAssertEqual(coordinator.open(cell, context: context(), tappedAt: 11), .routeActive)
        coordinator.dismissRoute(reason: "test")
        XCTAssertNil(coordinator.route)
    }

    @MainActor
    func testPagerBusyAndSnapshotRevisionRejectWithoutOpening() {
        let coordinator = TimetableEmptyCellSelectionCoordinator()
        coordinator.select(cell)
        XCTAssertEqual(coordinator.open(cell, context: context(pagerBusy: true), tappedAt: 10),
                       .pagerBusy)
        XCTAssertNil(coordinator.route)
        coordinator.clear(reason: "pager_busy")
        XCTAssertEqual(coordinator.open(cell, context: context(), tappedAt: 11), .selectionChanged)
        coordinator.select(cell)
        XCTAssertEqual(coordinator.open(cell, context: context(snapshotRevision: 3), tappedAt: 12),
                       .snapshotChanged)
        coordinator.clear(reason: "snapshot_changed")
        XCTAssertNil(coordinator.selected)
        XCTAssertNil(coordinator.route)
    }

    @MainActor
    func testTermAndAccountChangeRejectOldSelection() {
        let coordinator = TimetableEmptyCellSelectionCoordinator()
        coordinator.select(cell)
        XCTAssertEqual(coordinator.open(cell, context: context(termID: 9), tappedAt: 10), .termChanged)
        XCTAssertEqual(coordinator.open(cell, context: context(owner: nil), tappedAt: 11), .accountChanged)
        XCTAssertNil(coordinator.route)
    }

    @MainActor
    func testOldSheetDismissCallbackDoesNotClearNewSelection() {
        let coordinator = TimetableEmptyCellSelectionCoordinator()
        coordinator.select(cell)
        XCTAssertNil(coordinator.open(cell, context: context(), tappedAt: 10))
        coordinator.dismissRoute(reason: "sheet_closed")
        coordinator.select(cell)
        coordinator.sheetDidDismiss()
        XCTAssertEqual(coordinator.selected, cell)
        XCTAssertNil(coordinator.open(cell, context: context(), tappedAt: 11))
        XCTAssertNotNil(coordinator.route)
    }
}
