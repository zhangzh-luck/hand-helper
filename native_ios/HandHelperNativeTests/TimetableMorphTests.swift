import SwiftUI
import UIKit
import XCTest
@testable import HandHelperNative

final class TimetableMorphTests: XCTestCase {
    private let key = TimetableMorphSourceKey(authenticationRevision: 3, termID: 8, week: 2,
                                               snapshotRevision: 5, courseID: 11, placementIndex: 0)

    private func course() -> CourseSession {
        CourseSession(id: 11, name: "完整课程名称", date: "2026-09-08",
                      startDateTime: "2026-09-08T08:00:00", endDateTime: "2026-09-08T09:35:00",
                      room: "A101", teacher: "教师", weekExpression: "2周", source: "IMPORTED",
                      manualCourseID: nil, termID: 8, weekday: 2, startPeriod: 1, endPeriod: 2)
    }

    @MainActor
    private func mountedSource() -> (UIWindow, UIView, UIScrollView, UIView, TimetableCourseMorphCoordinator) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        let root = UIView(frame: window.bounds)
        window.addSubview(root)
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 120, width: 375, height: 580))
        scroll.contentSize = CGSize(width: 375, height: 1200)
        root.addSubview(scroll)
        let source = UIView(frame: CGRect(x: 70, y: 100, width: 42, height: 150))
        scroll.addSubview(source)
        let morph = TimetableCourseMorphCoordinator()
        morph.setRootView(root)
        morph.register(source, for: key)
        return (window, root, scroll, source, morph)
    }

    func testGeometryDestinationRespectsSafeArea() {
        let bounds = CGRect(x: 0, y: 0, width: 375, height: 812)
        let safe = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let result = TimetableMorphGeometry.destination(in: bounds, safeArea: safe)
        XCTAssertEqual(result.width, 343)
        XCTAssertLessThanOrEqual(result.height, 520)
        XCTAssertGreaterThanOrEqual(result.minY, 75)
        XCTAssertLessThanOrEqual(result.maxY, 762)
    }

    func testRectAndCornerInterpolationBoundaries() {
        let start = CGRect(x: 20, y: 100, width: 40, height: 80)
        let end = CGRect(x: 30, y: 200, width: 300, height: 400)
        XCTAssertEqual(TimetableMorphGeometry.interpolate(start, end, progress: -1), start)
        XCTAssertEqual(TimetableMorphGeometry.interpolate(start, end, progress: 1), end)
        XCTAssertEqual(TimetableMorphGeometry.interpolate(start, end, progress: 0.5),
                       CGRect(x: 25, y: 150, width: 170, height: 240))
        XCTAssertEqual(TimetableMorphGeometry.cornerRadius(progress: 0), 8)
        XCTAssertEqual(TimetableMorphGeometry.cornerRadius(progress: 1), 22)
    }

    @MainActor
    func testUIKitSourceConversionTracksVerticalScroll() {
        let (window, _, scroll, source, morph) = mountedSource()
        XCTAssertNotNil(window)
        XCTAssertEqual(morph.visibleSourceRect(for: key), CGRect(x: 70, y: 220, width: 42, height: 150))
        scroll.contentOffset.y = 40
        XCTAssertEqual(morph.visibleSourceRect(for: key), CGRect(x: 70, y: 180, width: 42, height: 150))
        XCTAssertTrue(source.window === window)
    }

    @MainActor
    func testPartlyClippedOrOtherWindowSourceHasNoMorphOrigin() {
        let (window, root, scroll, source, morph) = mountedSource()
        XCTAssertNotNil(window)
        scroll.contentOffset.y = 240
        XCTAssertNil(morph.visibleSourceRect(for: key))
        let otherWindow = UIWindow(frame: root.bounds)
        let otherRoot = UIView(frame: root.bounds)
        otherWindow.addSubview(otherRoot)
        morph.setRootView(otherRoot)
        scroll.contentOffset.y = 0
        XCTAssertNil(morph.visibleSourceRect(for: key))
        XCTAssertTrue(source.window === window)
    }

    @MainActor
    func testOpenPreventsRepeatAndCloseReturnsToSource() throws {
        let (window, _, _, _, morph) = mountedSource()
        XCTAssertNotNil(window)
        XCTAssertTrue(morph.open(course: course(), key: key, color: .blue))
        let id = try XCTUnwrap(morph.route?.id)
        XCTAssertEqual(morph.phase, .opening)
        XCTAssertTrue(morph.isHidden(key))
        XCTAssertFalse(morph.open(course: course(), key: key, color: .red))
        morph.markOpen(id: id)
        XCTAssertEqual(morph.phase, .open)
        XCTAssertNotNil(morph.beginClose(id: id))
        XCTAssertEqual(morph.phase, .closingToSource)
        morph.finish(id: id)
        XCTAssertEqual(morph.phase, .idle)
        XCTAssertFalse(morph.isHidden(key))
    }

    @MainActor
    func testLostSourceFadesAndOldCompletionCannotClearNewRoute() throws {
        let (window, _, scroll, _, morph) = mountedSource()
        XCTAssertNotNil(window)
        XCTAssertTrue(morph.open(course: course(), key: key, color: .blue))
        let first = try XCTUnwrap(morph.route?.id)
        scroll.contentOffset.y = 240
        XCTAssertNil(morph.beginClose(id: first))
        XCTAssertEqual(morph.phase, .fadingOut)
        morph.finish(id: first)
        scroll.contentOffset.y = 0
        XCTAssertTrue(morph.open(course: course(), key: key, color: .blue))
        let second = try XCTUnwrap(morph.route?.id)
        morph.finish(id: first)
        XCTAssertEqual(morph.route?.id, second)
    }

    @MainActor
    func testAuthenticationOrSnapshotChangeClearsCourseImmediately() {
        let (window, _, _, _, morph) = mountedSource()
        XCTAssertNotNil(window)
        XCTAssertTrue(morph.open(course: course(), key: key, color: .blue))
        morph.invalidate(termID: 8, snapshotRevision: 5, authenticationRevision: 4)
        XCTAssertNil(morph.route)
        XCTAssertEqual(morph.phase, .idle)
        XCTAssertTrue(morph.open(course: course(), key: key, color: .blue))
        morph.invalidate(termID: 8, snapshotRevision: 6, authenticationRevision: 3)
        XCTAssertNil(morph.route)
    }

    @MainActor
    func testPagerTransitionBlocksOpen() {
        let (window, _, _, _, morph) = mountedSource()
        XCTAssertNotNil(window)
        morph.setPagerBusy(true)
        XCTAssertFalse(morph.open(course: course(), key: key, color: .blue))
        morph.setPagerBusy(false)
        XCTAssertTrue(morph.open(course: course(), key: key, color: .blue))
    }
}
