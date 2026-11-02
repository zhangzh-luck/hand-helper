import SwiftUI
import XCTest
@testable import HandHelperNative

final class DestructiveConfirmationTests: XCTestCase {
    func testThreeDeletionCopies() {
        XCTAssertEqual(DestructiveConfirmationKind.grades.title, "删除本学期成绩？")
        XCTAssertEqual(DestructiveConfirmationKind.grades.deleteTitle, "删除成绩")
        XCTAssertTrue(DestructiveConfirmationKind.grades.message.contains("AI 分析缓存"))
        XCTAssertTrue(DestructiveConfirmationKind.grades.message.contains("其他学期不受影响"))
        XCTAssertEqual(DestructiveConfirmationKind.schedule.title, "删除这项安排？")
        XCTAssertEqual(DestructiveConfirmationKind.schedule.deleteTitle, "删除安排")
        XCTAssertEqual(DestructiveConfirmationKind.schedule.message, "删除后无法恢复这项自定义安排。")
        XCTAssertEqual(DestructiveConfirmationKind.manualCourse.title, "删除这门课程？")
        XCTAssertEqual(DestructiveConfirmationKind.manualCourse.deleteTitle, "删除课程")
        XCTAssertEqual(DestructiveConfirmationKind.manualCourse.message,
                       "删除后这门手动课程将从本机课程表移除。")
    }

    @MainActor
    func testCancelNeverCallsDeleteAndReturnsToIdle() throws {
        let confirmation = DestructiveConfirmationCoordinator()
        var deletes = 0
        var cancels = 0
        XCTAssertTrue(confirmation.present(.schedule, confirm: { deletes += 1 },
                                            cancel: { cancels += 1 }))
        let id = try XCTUnwrap(confirmation.request?.id)
        XCTAssertTrue(confirmation.beginClose(id: id, confirmed: false))
        confirmation.hide(id: id)
        XCTAssertTrue(confirmation.isPresenting, "关闭动画期间继续阻断底层触摸")
        confirmation.finish(id: id)
        XCTAssertEqual(deletes, 0)
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(confirmation.phase, .idle)
        XCTAssertFalse(confirmation.isPresenting)
    }

    @MainActor
    func testConfirmationRunsExactlyOnceAfterClosing() throws {
        for kind in [DestructiveConfirmationKind.grades, .schedule, .manualCourse] {
            let confirmation = DestructiveConfirmationCoordinator()
            var deletes = 0
            XCTAssertTrue(confirmation.present(kind, confirm: { deletes += 1 }, cancel: {}))
            let id = try XCTUnwrap(confirmation.request?.id)
            XCTAssertFalse(confirmation.present(kind, confirm: { deletes += 1 }, cancel: {}))
            XCTAssertTrue(confirmation.beginClose(id: id, confirmed: true))
            XCTAssertFalse(confirmation.beginClose(id: id, confirmed: true))
            confirmation.hide(id: id)
            XCTAssertEqual(deletes, 0)
            XCTAssertTrue(confirmation.isExecuting)
            confirmation.finish(id: id)
            confirmation.finish(id: id)
            XCTAssertEqual(deletes, 1)
            XCTAssertFalse(confirmation.isPresenting)
        }
    }

    @MainActor
    func testInvalidationCancelsPendingConfirmationAndOldCompletion() throws {
        let confirmation = DestructiveConfirmationCoordinator()
        var deletes = 0
        var cancels = 0
        XCTAssertTrue(confirmation.present(.grades, confirm: { deletes += 1 },
                                            cancel: { cancels += 1 }))
        let oldID = try XCTUnwrap(confirmation.request?.id)
        XCTAssertTrue(confirmation.beginClose(id: oldID, confirmed: true))
        confirmation.hide(id: oldID)
        confirmation.clear() // Account, term, or target became invalid.
        confirmation.finish(id: oldID)
        XCTAssertEqual(deletes, 0)
        XCTAssertEqual(cancels, 1)
        XCTAssertTrue(confirmation.present(.manualCourse, confirm: { deletes += 1 }, cancel: {}))
        let newID = try XCTUnwrap(confirmation.request?.id)
        confirmation.finish(id: oldID)
        XCTAssertEqual(confirmation.request?.id, newID)
    }

    @MainActor
    func testManualCoursePromptReturnsToExistingDetailOnCancel() throws {
        let detail = TimetableCourseDetailCoordinator()
        let course = CourseSession(id: 11, name: "手动课程", date: "2026-09-08",
            startDateTime: "2026-09-08T08:00:00", endDateTime: "2026-09-08T09:35:00",
            room: nil, teacher: nil, weekExpression: "2周", source: "MANUAL",
            manualCourseID: -7, termID: 8, weekday: 2, startPeriod: 1, endPeriod: 2)
        let context = TimetableDetailContext(authenticationRevision: 3, termID: 8,
            week: 2, snapshotRevision: 5, courseID: 11, placementIndex: 0)
        XCTAssertTrue(detail.open(course: course, context: context, color: .blue,
            editableManualCourse: TimetableManualCourseIdentity(owner: "user:alice", ruleID: -7)))
        let detailID = try XCTUnwrap(detail.route?.id)
        XCTAssertTrue(detail.requestDelete(id: detailID))
        let confirmation = DestructiveConfirmationCoordinator()
        XCTAssertTrue(confirmation.present(.manualCourse,
            confirm: { _ = detail.confirmDelete() }, cancel: { detail.cancelDelete() }))
        let confirmID = try XCTUnwrap(confirmation.request?.id)
        XCTAssertTrue(confirmation.beginClose(id: confirmID, confirmed: false))
        confirmation.hide(id: confirmID)
        confirmation.finish(id: confirmID)
        XCTAssertNil(detail.pendingDelete)
        XCTAssertEqual(detail.route?.id, detailID)
        XCTAssertNil(detail.readyAction)
    }

    func testSurfaceFallbackPolicy() {
        XCTAssertEqual(DestructiveConfirmationSurface.current(supportsGlass: true,
            reduceTransparency: false, increasedContrast: false), .glass)
        XCTAssertEqual(DestructiveConfirmationSurface.current(supportsGlass: false,
            reduceTransparency: false, increasedContrast: false), .material)
        XCTAssertEqual(DestructiveConfirmationSurface.current(supportsGlass: true,
            reduceTransparency: true, increasedContrast: false), .opaque)
        XCTAssertEqual(DestructiveConfirmationSurface.current(supportsGlass: true,
            reduceTransparency: false, increasedContrast: true), .opaque)
    }
}
