import SwiftUI
import UIKit
import XCTest
@testable import HandHelperNative

final class TimetableMorphTests: XCTestCase {
    private let key = TimetableMorphSourceKey(authenticationRevision: 3, termID: 8, week: 2,
                                               snapshotRevision: 5, courseID: 11, placementIndex: 0)

    private func course(name: String = "完整课程名称") -> CourseSession {
        CourseSession(id: 11, name: name, date: "2026-09-08",
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
        let result = TimetableMorphGeometry.destination(in: bounds, safeArea: safe,
                                                        preferredHeight: 300)
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
        XCTAssertEqual(TimetableMorphGeometry.cornerRadius(progress: 0), 9)
        XCTAssertEqual(TimetableMorphGeometry.cornerRadius(progress: 1), 22)
    }

    func testReverseAtIntermediateProgressKeepsCurrentGeometry() {
        let source = CGRect(x: 20, y: 100, width: 42, height: 150)
        let target = CGRect(x: 30, y: 210, width: 315, height: 300)
        for progress in [CGFloat(0.2), 0.5, 0.9] {
            let current = TimetableMorphTimeline.frame(from: source, to: target, progress: progress)
            let presentation = TimetableMorphPresentation()
            presentation.record(current)
            XCTAssertEqual(presentation.current().progress, progress)
            XCTAssertEqual(presentation.current().rect, current.rect)
            let previous = TimetableMorphTimeline.frame(from: source, to: target,
                                                        progress: progress - 0.001)
            XCTAssertLessThan(abs(previous.rect.midX - current.rect.midX), 1)
            XCTAssertLessThan(abs(previous.rect.midY - current.rect.midY), 1)
            XCTAssertEqual(TimetableMorphTimeline.frame(from: source, to: target,
                                                        progress: 0).rect, source)
        }
    }

    func testMissingSourceFreezesActualIntermediateRectangle() {
        let source = CGRect(x: 20, y: 100, width: 42, height: 150)
        let target = CGRect(x: 30, y: 210, width: 315, height: 300)
        let current = TimetableMorphTimeline.frame(from: source, to: target, progress: 0.5)
        let frozen = TimetableMorphTimeline.frame(from: source, to: target,
                                                  progress: 0.25, frozenRect: current.rect)
        XCTAssertEqual(frozen.rect, current.rect)
        XCTAssertEqual(frozen.progress, 0.25)
        XCTAssertNotEqual(frozen.rect, target)
    }

    func testContentHandoffUsesOneContinuousProgress() {
        XCTAssertEqual(TimetableMorphTimeline.phase(0.18, from: 0.18, to: 0.34), 0)
        XCTAssertEqual(TimetableMorphTimeline.phase(0.26, from: 0.18, to: 0.34), 0.5,
                       accuracy: 0.0001)
        XCTAssertEqual(TimetableMorphTimeline.phase(0.45, from: 0.30, to: 0.45), 1)
        XCTAssertGreaterThan(TimetableMorphTimeline.geometryProgress(0.5), 0.5)
    }

    func testContentHeightUsesMeasuredValueAndSafeAreaCap() {
        let bounds = CGRect(x: 0, y: 0, width: 375, height: 812)
        let safe = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let compact = TimetableMorphGeometry.destination(in: bounds, safeArea: safe,
                                                          preferredHeight: 240)
        let expanded = TimetableMorphGeometry.destination(in: bounds, safeArea: safe,
                                                           preferredHeight: 410)
        let capped = TimetableMorphGeometry.destination(in: bounds, safeArea: safe,
                                                         preferredHeight: 900)
        XCTAssertEqual(compact.height, 240)
        XCTAssertEqual(expanded.height, 410)
        XCTAssertEqual(capped.height, 520)
        XCTAssertGreaterThanOrEqual(capped.minY, 75)
        XCTAssertLessThanOrEqual(capped.maxY, 762)
    }

    @MainActor
    func testActualDetailHeightRespondsToLongTitleAndDynamicType() {
        func measuredHeight(name: String, dynamicType: DynamicTypeSize) -> CGFloat {
            let content = TimetableMorphDetailContent(
                course: course(name: name), courseColor: .blue,
                headerOpacity: 1, bodyOpacity: 1, bodyOffset: 0,
                focusTitle: false, onClose: {}
            )
            let host = UIHostingController(rootView: content
                .frame(width: 343)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.dynamicTypeSize, dynamicType))
            return host.sizeThatFits(in: CGSize(width: 343, height: 2_000)).height
        }

        let ordinary = measuredHeight(name: "机器学习", dynamicType: .medium)
        let longTitle = measuredHeight(name: String(repeating: "Python 数据分析与可视化技术", count: 4),
                                       dynamicType: .medium)
        let accessible = measuredHeight(name: "机器学习", dynamicType: .accessibility2)
        XCTAssertGreaterThan(ordinary, 0)
        XCTAssertGreaterThan(longTitle, ordinary)
        XCTAssertGreaterThan(accessible, ordinary)
    }

    @MainActor
    func testCompletionCannotChangeWrongPhaseOrRoute() throws {
        let (window, _, _, _, morph) = mountedSource()
        XCTAssertNotNil(window)
        XCTAssertTrue(morph.open(course: course(), key: key, color: .blue))
        let first = try XCTUnwrap(morph.route?.id)
        morph.finish(id: first)
        XCTAssertEqual(morph.phase, .opening)
        morph.markOpen(id: first)
        XCTAssertEqual(morph.phase, .open)
        XCTAssertNotNil(morph.beginClose(id: first))
        morph.finish(id: first)
        XCTAssertTrue(morph.open(course: course(), key: key, color: .blue))
        let second = try XCTUnwrap(morph.route?.id)
        morph.markOpen(id: first)
        morph.finish(id: first)
        XCTAssertEqual(morph.route?.id, second)
        XCTAssertEqual(morph.phase, .opening)
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
        XCTAssertNil(morph.beginClose(id: id))
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
        XCTAssertTrue(morph.open(course: course(), key: key, color: .blue))
        morph.invalidate(termID: 9, snapshotRevision: 5, authenticationRevision: 3)
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

    @MainActor
    func testClearingOverlayKeepsMountedCardMarkerForNextTap() {
        let (window, _, _, _, morph) = mountedSource()
        XCTAssertNotNil(window)
        XCTAssertTrue(morph.open(course: course(), key: key, color: .blue))
        morph.clear()
        XCTAssertNotNil(morph.visibleSourceRect(for: key))
        XCTAssertTrue(morph.open(course: course(), key: key, color: .blue))
    }
}
