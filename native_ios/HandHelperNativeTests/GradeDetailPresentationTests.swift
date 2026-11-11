import SwiftUI
import UIKit
import XCTest
@testable import HandHelperNative

final class GradeDetailPresentationTests: XCTestCase {
    private func grade(id: Int = 4, termID: Int = 8, score: String = "良好") -> GradeRecord {
        GradeRecord(id: id, termID: termID, courseCode: "C001", courseName: "机器学习",
                    courseType: "必修", credits: 2.5, score: score, finalExamScore: "82",
                    usualScore: "90", gradePoint: 3.2, weightedGradePoint: 8,
                    examType: "考试", makeupFlag: false, retakeFlag: true)
    }

    private func context(owner: String = "user:alice", revision: Int = 3,
                         termID: Int = 8, gradeID: Int = 4) -> GradeDetailContext {
        GradeDetailContext(owner: owner, authenticationRevision: revision,
                           termID: termID, gradeID: gradeID)
    }

    @MainActor
    func testOpenCloseAndRepeatedTap() throws {
        let detail = GradeDetailCoordinator()
        XCTAssertFalse(detail.open(grade: grade(), context: context(gradeID: 5)))
        XCTAssertFalse(detail.open(grade: grade(), context: context(termID: 9)))
        XCTAssertTrue(detail.open(grade: grade(), context: context()))
        let id = try XCTUnwrap(detail.route?.id)
        XCTAssertEqual(detail.phase, .opening)
        XCTAssertFalse(detail.open(grade: grade(id: 5), context: context(gradeID: 5)))
        detail.markOpen(id: id)
        XCTAssertEqual(detail.phase, .open)
        XCTAssertTrue(detail.beginClose(id: id))
        XCTAssertFalse(detail.beginClose(id: id))
        XCTAssertEqual(detail.phase, .closing)
        detail.finish(id: id)
        XCTAssertEqual(detail.phase, .idle)
        XCTAssertNil(detail.route)
    }

    @MainActor
    func testClosingDuringOpeningAndStaleCallbacks() throws {
        let detail = GradeDetailCoordinator()
        XCTAssertTrue(detail.open(grade: grade(), context: context()))
        let oldID = try XCTUnwrap(detail.route?.id)
        XCTAssertTrue(detail.beginClose(id: oldID))
        detail.markOpen(id: oldID)
        XCTAssertEqual(detail.phase, .closing)
        detail.finish(id: oldID)
        XCTAssertTrue(detail.open(grade: grade(id: 5), context: context(gradeID: 5)))
        let newID = try XCTUnwrap(detail.route?.id)
        detail.finish(id: oldID)
        detail.markOpen(id: oldID)
        XCTAssertEqual(detail.route?.id, newID)
        XCTAssertEqual(detail.phase, .opening)
    }

    @MainActor
    func testClearingAnIdleCoordinatorDoesNotPublishAnotherStateChange() throws {
        let detail = GradeDetailCoordinator()
        XCTAssertFalse(detail.clear())
        XCTAssertTrue(detail.open(grade: grade(), context: context()))
        XCTAssertTrue(detail.clear())
        XCTAssertFalse(detail.clear())
        XCTAssertNil(detail.route)
        XCTAssertEqual(detail.phase, .idle)
    }

    @MainActor
    func testAuthenticationTermAndRefreshedGradeInvalidateRoute() throws {
        for (owner, revision, termID, record) in [
            ("user:bob", 3, 8, grade()),
            ("user:alice", 4, 8, grade()),
            ("user:alice", 3, 9, grade()),
            ("user:alice", 3, 8, grade(score: "优秀"))
        ] {
            let detail = GradeDetailCoordinator()
            XCTAssertTrue(detail.open(grade: grade(), context: context()))
            detail.invalidate(owner: owner, authenticationRevision: revision,
                              termID: termID, grade: record)
            XCTAssertNil(detail.route)
            XCTAssertEqual(detail.phase, .idle)
        }
        let detail = GradeDetailCoordinator()
        XCTAssertTrue(detail.open(grade: grade(), context: context()))
        detail.invalidate(owner: "user:alice", authenticationRevision: 3,
                          termID: 8, grade: grade())
        XCTAssertNotNil(detail.route)
        detail.invalidate(owner: "user:alice", authenticationRevision: 3,
                          termID: 8, grade: nil)
        XCTAssertNil(detail.route)
    }

    func testContentHeightAndSafeAreaDetermineCenteredFrame() {
        let bounds = CGRect(x: 0, y: 0, width: 375, height: 812)
        let safe = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let short = GradeDetailLayout.frame(in: bounds, safeArea: safe, contentHeight: 280)
        let capped = GradeDetailLayout.frame(in: bounds, safeArea: safe, contentHeight: 900)
        XCTAssertEqual(short.width, 343)
        XCTAssertEqual(short.height, 280)
        XCTAssertEqual(capped.height, 520)
        XCTAssertGreaterThanOrEqual(short.minY, safe.top + 16)
        XCTAssertLessThanOrEqual(capped.maxY, bounds.maxY - safe.bottom - 16)
        XCTAssertFalse(GradeDetailLayout.needsScrolling(contentHeight: 280.5,
                                                         viewportHeight: short.height))
        XCTAssertTrue(GradeDetailLayout.needsScrolling(contentHeight: 900,
                                                        viewportHeight: capped.height))

        let landscape = GradeDetailLayout.frame(
            in: CGRect(x: 0, y: 0, width: 812, height: 375),
            safeArea: UIEdgeInsets(top: 20, left: 0, bottom: 21, right: 0),
            contentHeight: 900)
        XCTAssertEqual(landscape.width, 420)
        XCTAssertEqual(landscape.height, 302)
        XCTAssertTrue(GradeDetailLayout.needsScrolling(contentHeight: 900,
                                                        viewportHeight: landscape.height))
    }

    func testMotionAndAccessibilitySurfaceFallback() {
        XCTAssertEqual(GradeDetailMotion.openingDuration, TimetableDetailMotion.openingDuration)
        XCTAssertEqual(GradeDetailMotion.closingDuration, TimetableDetailMotion.closingDuration)
        XCTAssertEqual(GradeDetailMotion.scrimOpacity(dark: false), 0.32)
        XCTAssertEqual(GradeDetailMotion.scrimOpacity(dark: true), 0.42)
        XCTAssertLessThan(GradeDetailMotion.reducedDuration, GradeDetailMotion.openingDuration)
        XCTAssertEqual(GradeDetailSurfaceKind.current(reduceTransparency: false,
            increasedContrast: false, supportsGlass: true), .glass)
        XCTAssertEqual(GradeDetailSurfaceKind.current(reduceTransparency: false,
            increasedContrast: false, supportsGlass: false), .material)
        XCTAssertEqual(GradeDetailSurfaceKind.current(reduceTransparency: true,
            increasedContrast: false, supportsGlass: true), .opaque)
        XCTAssertEqual(GradeDetailSurfaceKind.current(reduceTransparency: false,
            increasedContrast: true, supportsGlass: true), .opaque)
    }
}
