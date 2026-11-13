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

    func testEditDraftPrefillsEveryManualFieldWithoutMutatingOriginal() {
        let original = ManualCourseRule(id: -7, termSourceID: "fall", name: "机器学习",
            weeks: [1, 3, 5], weekday: 4, startPeriod: 2, endPeriod: 7,
            room: "A101", teacher: "张老师", remoteID: nil)
        var draft = ManualCourseDraft(rule: original)
        XCTAssertEqual(draft.name, original.name)
        XCTAssertEqual(draft.weeks, Set(original.weeks))
        XCTAssertEqual(draft.weekday, original.weekday)
        XCTAssertEqual(draft.startPeriod, original.startPeriod)
        XCTAssertEqual(draft.endPeriod, original.endPeriod)
        XCTAssertEqual(draft.room, original.room ?? "")
        XCTAssertEqual(draft.teacher, original.teacher ?? "")
        draft.name = "修改后"
        draft.weeks = [2]
        XCTAssertEqual(original.name, "机器学习", "取消编辑只丢弃尚未保存的草稿")
        XCTAssertEqual(original.weeks, [1, 3, 5])
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

    func testWeekTilesToggleEveryWeekAndBulkSelections() {
        XCTAssertEqual(ManualCourseWeekChoices.all, Set(1...20))
        XCTAssertEqual(ManualCourseWeekChoices.odd, Set(stride(from: 1, through: 19, by: 2)))
        XCTAssertEqual(ManualCourseWeekChoices.even, Set(stride(from: 2, through: 20, by: 2)))
        XCTAssertTrue(ManualCourseWeekChoices.odd.isDisjoint(with: ManualCourseWeekChoices.even))
        var selected = Set<Int>()
        for week in 1...20 {
            selected = ManualCourseWeekChoices.toggling(week, in: selected)
        }
        XCTAssertEqual(selected, ManualCourseWeekChoices.all)
        for week in 1...20 {
            selected = ManualCourseWeekChoices.toggling(week, in: selected)
        }
        XCTAssertTrue(selected.isEmpty)
    }

    func testWeekPickerCancelKeepsFormWeeksAndCompleteRequiresSelection() {
        var formWeeks: Set<Int> = [3]
        var picker = ManualCourseWeekDraft(weeks: formWeeks)
        picker.replace(with: ManualCourseWeekChoices.odd)
        XCTAssertEqual(formWeeks, [3]) // Cancelling drops the picker without writing the binding.
        XCTAssertEqual(picker.completedSelection, ManualCourseWeekChoices.odd)
        formWeeks = picker.completedSelection ?? formWeeks
        XCTAssertEqual(formWeeks, ManualCourseWeekChoices.odd)
        picker.replace(with: [])
        XCTAssertNil(picker.completedSelection)
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
    func testSelectionSurvivesScrollingAndCancelledPagingUntilWeekChanges() {
        let coordinator = TimetableEmptyCellSelectionCoordinator()
        coordinator.select(cell)
        // Vertical scrolling has no selection mutation; a cancelled page transition
        // also leaves the selected teaching week unchanged.
        XCTAssertEqual(coordinator.selected, cell)
        XCTAssertEqual(coordinator.open(cell, context: context(pagerBusy: true), tappedAt: 10),
                       .pagerBusy)
        XCTAssertEqual(coordinator.selected, cell)
        XCTAssertNil(coordinator.route)
        XCTAssertEqual(coordinator.selected, cell) // Pager settled on the original week.
        coordinator.clear(reason: "week_changed")
        XCTAssertNil(coordinator.selected)
    }

    @MainActor
    func testSelectingSameCellKeepsSelectionAndAnotherCellMovesIt() {
        let coordinator = TimetableEmptyCellSelectionCoordinator()
        coordinator.select(cell)
        coordinator.select(cell)
        XCTAssertEqual(coordinator.selected, cell)
        let otherCell = TimetableEmptyCellSelection(owner: cell.owner,
            authenticationRevision: cell.authenticationRevision, termID: cell.termID,
            week: cell.week, snapshotRevision: cell.snapshotRevision,
            weekday: 3, periodNumber: cell.periodNumber)
        coordinator.select(otherCell)
        XCTAssertEqual(coordinator.selected, otherCell)
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
        XCTAssertEqual(coordinator.selected, cell)
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

    @MainActor
    func testOverlayCoordinatorIgnoresDuplicatesAndFinishesOnlyCurrentRoute() {
        let coordinator = ManualCourseEditorCoordinator()
        var firstFinishCount = 0
        var secondFinishCount = 0
        let draft = ManualCourseDraft(cell: cell)

        coordinator.present(draft: draft, periods: [], isEditing: false, onSave: { _ in }, onFinish: {
            firstFinishCount += 1
        })
        let firstID = try! XCTUnwrap(coordinator.route?.id)
        coordinator.present(draft: draft, periods: [], isEditing: false, onSave: { _ in }, onFinish: {
            secondFinishCount += 1
        })
        XCTAssertEqual(coordinator.route?.id, firstID)

        coordinator.show(id: firstID)
        XCTAssertTrue(coordinator.isVisible)
        XCTAssertTrue(coordinator.prepareDismissal(id: firstID))
        coordinator.hide(id: firstID)
        coordinator.finishDismissal(id: firstID)
        XCTAssertNil(coordinator.route)
        XCTAssertEqual(firstFinishCount, 1)
        XCTAssertEqual(secondFinishCount, 0)
    }

    @MainActor
    func testOverlayCoordinatorClearMakesStaleCompletionHarmless() {
        let coordinator = ManualCourseEditorCoordinator()
        var finishCount = 0
        coordinator.present(draft: ManualCourseDraft(cell: cell), periods: [], isEditing: false,
                            onSave: { _ in }, onFinish: { finishCount += 1 })
        let routeID = try! XCTUnwrap(coordinator.route?.id)
        coordinator.show(id: routeID)
        XCTAssertTrue(coordinator.prepareDismissal(id: routeID))
        coordinator.clear()
        coordinator.finishDismissal(id: routeID)
        XCTAssertNil(coordinator.route)
        XCTAssertEqual(finishCount, 0)
    }

    func testCompactFormViewportNeverExceedsAvailableHeight() {
        XCTAssertEqual(ManualCourseEditorLayout.formViewportHeight(contentHeight: 180, maximum: 300), 180)
        XCTAssertEqual(ManualCourseEditorLayout.formViewportHeight(contentHeight: 480, maximum: 300), 300)
        XCTAssertEqual(ManualCourseEditorLayout.maximumFormHeight(in: 160), 120)
    }

    func testWeekPickerViewportStaysCompactUntilSpaceIsConstrained() {
        XCTAssertEqual(ManualCourseWeekPickerLayout.gridViewportHeight(contentHeight: 260, maximum: 360), 260)
        XCTAssertEqual(ManualCourseWeekPickerLayout.gridViewportHeight(contentHeight: 480, maximum: 360), 360)
        XCTAssertEqual(ManualCourseWeekPickerLayout.maximumGridHeight(in: 180), 140)
    }

    func testWeekPickerControlsKeepCompactVisualsAndAccessibleTargets() {
        XCTAssertEqual(ManualCourseWeekPickerControlLayout.compactVisualHeight, 38)
        XCTAssertGreaterThanOrEqual(ManualCourseWeekPickerControlLayout.minimumTouchHeight, 44)
        XCTAssertEqual(ManualCourseWeekPickerControlLayout.completeHeight, 52)
        XCTAssertEqual(ManualCourseWeekPickerControlLayout.controlSpacing, 8)
    }

    @MainActor
    func testCourseEditorKeyboardSuppressionPolicyIsScopedToCourseEditor() {
        XCTAssertTrue(NativeTabController.shouldSuppressKeyboardTabBarUpdates(forManualCourseEditor: true))
        XCTAssertFalse(NativeTabController.shouldSuppressKeyboardTabBarUpdates(forManualCourseEditor: false))
    }
}
