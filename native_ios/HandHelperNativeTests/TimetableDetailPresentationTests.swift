import SwiftUI
import UIKit
import XCTest
@testable import HandHelperNative

final class TimetableDetailPresentationTests: XCTestCase {
    private let context = TimetableDetailContext(authenticationRevision: 3, termID: 8,
                                                 week: 2, snapshotRevision: 5,
                                                 courseID: 11, placementIndex: 0)

    private func course(name: String = "完整课程名称") -> CourseSession {
        CourseSession(id: 11, name: name, date: "2026-09-08",
                      startDateTime: "2026-09-08T08:00:00", endDateTime: "2026-09-08T09:35:00",
                      room: "A101", teacher: "教师", weekExpression: "2周", source: "IMPORTED",
                      manualCourseID: nil, termID: 8, weekday: 2, startPeriod: 1, endPeriod: 2)
    }

    func testDetailFrameUsesContentHeightAndSafeArea() {
        let bounds = CGRect(x: 0, y: 0, width: 375, height: 812)
        let safe = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let short = TimetableDetailLayout.frame(in: bounds, safeArea: safe, preferredHeight: 240)
        let long = TimetableDetailLayout.frame(in: bounds, safeArea: safe, preferredHeight: 410)
        let capped = TimetableDetailLayout.frame(in: bounds, safeArea: safe, preferredHeight: 900)
        XCTAssertEqual(short.width, 343)
        XCTAssertEqual(short.height, 240)
        XCTAssertEqual(long.height, 410)
        XCTAssertEqual(capped.height, 520)
        XCTAssertEqual(short.midX, bounds.midX)
        XCTAssertGreaterThanOrEqual(capped.minY, 75)
        XCTAssertLessThanOrEqual(capped.maxY, 762)
    }

    func testSmallWindowCapsHeightWithinSafeArea() {
        let frame = TimetableDetailLayout.frame(
            in: CGRect(x: 0, y: 0, width: 320, height: 420),
            safeArea: UIEdgeInsets(top: 50, left: 0, bottom: 34, right: 0),
            preferredHeight: 900)
        XCTAssertEqual(frame.width, 288)
        XCTAssertEqual(frame.height, 304)
        XCTAssertEqual(frame.minY, 66)
        XCTAssertEqual(frame.maxY, 370)
    }

    func testNativeMotionUsesOneVisibleStateAndReducedMotionFallback() {
        XCTAssertEqual(TimetableDetailMotion.scale(visible: false, reduceMotion: false), 0.96)
        XCTAssertEqual(TimetableDetailMotion.verticalOffset(visible: false, reduceMotion: false), 6)
        XCTAssertEqual(TimetableDetailMotion.scale(visible: true, reduceMotion: false), 1)
        XCTAssertEqual(TimetableDetailMotion.verticalOffset(visible: true, reduceMotion: false), 0)
        XCTAssertEqual(TimetableDetailMotion.scale(visible: false, reduceMotion: true), 1)
        XCTAssertEqual(TimetableDetailMotion.verticalOffset(visible: false, reduceMotion: true), 0)
        XCTAssertLessThan(TimetableDetailMotion.reducedDuration, TimetableDetailMotion.openingDuration)
        XCTAssertEqual(TimetableDetailMotion.scrimOpacity(dark: false), 0.32)
        XCTAssertEqual(TimetableDetailMotion.scrimOpacity(dark: true), 0.42)
    }

    @MainActor
    func testOrdinaryCourseOpensCorrectDetailAndRejectsRepeat() throws {
        let detail = TimetableCourseDetailCoordinator()
        XCTAssertTrue(detail.open(course: course(), context: context, color: .blue))
        let route = try XCTUnwrap(detail.route)
        XCTAssertEqual(route.course.name, "完整课程名称")
        XCTAssertEqual(route.context, context)
        XCTAssertEqual(detail.phase, .opening)
        XCTAssertFalse(detail.open(course: course(name: "其他课程"), context: context, color: .red))
        XCTAssertEqual(detail.route?.id, route.id)
    }

    @MainActor
    func testOpeningCanBeClosedAndOldOpenCompletionIsIgnored() throws {
        let detail = TimetableCourseDetailCoordinator()
        XCTAssertTrue(detail.open(course: course(), context: context, color: .blue))
        let id = try XCTUnwrap(detail.route?.id)
        XCTAssertTrue(detail.beginClose(id: id))
        XCTAssertEqual(detail.phase, .closing)
        detail.markOpen(id: id)
        XCTAssertEqual(detail.phase, .closing)
        XCTAssertFalse(detail.beginClose(id: id))
        detail.finish(id: id)
        XCTAssertEqual(detail.phase, .idle)
        XCTAssertNil(detail.route)
    }

    @MainActor
    func testOldCompletionCannotClearNewRoute() throws {
        let detail = TimetableCourseDetailCoordinator()
        XCTAssertTrue(detail.open(course: course(), context: context, color: .blue))
        let old = try XCTUnwrap(detail.route?.id)
        XCTAssertTrue(detail.beginClose(id: old))
        detail.finish(id: old)
        XCTAssertTrue(detail.open(course: course(name: "新课程"), context: context, color: .red))
        let current = try XCTUnwrap(detail.route?.id)
        detail.markOpen(id: old)
        detail.finish(id: old)
        XCTAssertEqual(detail.route?.id, current)
        XCTAssertEqual(detail.phase, .opening)
    }

    @MainActor
    func testAuthenticationTermAndSnapshotChangesClearDetail() {
        let detail = TimetableCourseDetailCoordinator()
        for (term, snapshot, authentication) in [(8, 5, 4), (9, 5, 3), (8, 6, 3)] {
            XCTAssertTrue(detail.open(course: course(), context: context, color: .blue))
            detail.invalidate(termID: term, snapshotRevision: snapshot,
                              authenticationRevision: authentication)
            XCTAssertNil(detail.route)
            XCTAssertEqual(detail.phase, .idle)
        }
    }

    @MainActor
    func testMatchingIdentityRetainsDetailAndPagerBlocksOpening() {
        let detail = TimetableCourseDetailCoordinator()
        detail.setPagerBusy(true)
        XCTAssertFalse(detail.open(course: course(), context: context, color: .blue))
        detail.setPagerBusy(false)
        XCTAssertTrue(detail.open(course: course(), context: context, color: .blue))
        detail.invalidate(termID: 8, snapshotRevision: 5, authenticationRevision: 3)
        XCTAssertNotNil(detail.route)
        detail.clear()
        XCTAssertNil(detail.route)
    }

    @MainActor
    func testLongTitleAndDynamicTypeIncreaseMeasuredContentHeight() {
        func height(name: String, size: DynamicTypeSize) -> CGFloat {
            let view = TimetableDetailContent(course: course(name: name), courseColor: .blue,
                                              focusTitle: false, onClose: {})
                .frame(width: 343)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.dynamicTypeSize, size)
            return UIHostingController(rootView: view)
                .sizeThatFits(in: CGSize(width: 343, height: 2_000)).height
        }
        let short = height(name: "机器学习", size: .medium)
        XCTAssertGreaterThan(short, 0)
        XCTAssertGreaterThan(height(name: String(repeating: "Python 数据分析与可视化技术", count: 4),
                                    size: .medium), short)
        XCTAssertGreaterThan(height(name: "机器学习", size: .accessibility2), short)
    }
}
