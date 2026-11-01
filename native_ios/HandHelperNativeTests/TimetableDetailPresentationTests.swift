import SwiftUI
import UIKit
import XCTest
@testable import HandHelperNative

final class TimetableDetailPresentationTests: XCTestCase {
    private let context = TimetableDetailContext(authenticationRevision: 3, termID: 8,
                                                 week: 2, snapshotRevision: 5,
                                                 courseID: 11, placementIndex: 0)

    private func course(name: String = "完整课程名称", room: String? = "A101",
                        teacher: String? = "教师", weeks: String? = "2周") -> CourseSession {
        CourseSession(id: 11, name: name, date: "2026-09-08",
                      startDateTime: "2026-09-08T08:00:00", endDateTime: "2026-09-08T09:35:00",
                      room: room, teacher: teacher, weekExpression: weeks, source: "IMPORTED",
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
        XCTAssertEqual(TimetableDetailMotion.scale(visible: false, reduceMotion: false), 0.92)
        XCTAssertEqual(TimetableDetailMotion.verticalOffset(visible: false, reduceMotion: false), 10)
        XCTAssertEqual(TimetableDetailMotion.scale(visible: true, reduceMotion: false), 1)
        XCTAssertEqual(TimetableDetailMotion.verticalOffset(visible: true, reduceMotion: false), 0)
        XCTAssertEqual(TimetableDetailMotion.scale(visible: false, reduceMotion: true), 1)
        XCTAssertEqual(TimetableDetailMotion.verticalOffset(visible: false, reduceMotion: true), 0)
        XCTAssertLessThan(TimetableDetailMotion.reducedDuration, TimetableDetailMotion.openingDuration)
        XCTAssertEqual(TimetableDetailMotion.scrimOpacity(dark: false), 0.32)
        XCTAssertEqual(TimetableDetailMotion.scrimOpacity(dark: true), 0.42)
        XCTAssertEqual(TimetableDetailMotion.openingDuration, 0.32)
        XCTAssertEqual(TimetableDetailMotion.closingDuration, 0.22)
    }

    func testGlassMaterialAndAccessibleOpaqueSurfacePolicy() {
        XCTAssertEqual(TimetableDetailSurfaceKind.current(reduceTransparency: false,
                                                          increasedContrast: false,
                                                          supportsGlass: true), .glass)
        XCTAssertEqual(TimetableDetailSurfaceKind.current(reduceTransparency: false,
                                                          increasedContrast: false,
                                                          supportsGlass: false), .material)
        for supportsGlass in [false, true] {
            XCTAssertEqual(TimetableDetailSurfaceKind.current(reduceTransparency: true,
                                                              increasedContrast: false,
                                                              supportsGlass: supportsGlass), .opaque)
            XCTAssertEqual(TimetableDetailSurfaceKind.current(reduceTransparency: false,
                                                              increasedContrast: true,
                                                              supportsGlass: supportsGlass), .opaque)
        }
    }

    @MainActor
    func testOpeningCompletionOnlyAdvancesCurrentOpeningRoute() throws {
        let detail = TimetableCourseDetailCoordinator()
        XCTAssertTrue(detail.open(course: course(), context: context, color: .blue))
        let id = try XCTUnwrap(detail.route?.id)
        detail.markOpen(id: UUID())
        XCTAssertEqual(detail.phase, .opening)
        detail.markOpen(id: id)
        XCTAssertEqual(detail.phase, .open)
        XCTAssertTrue(detail.beginClose(id: id))
        detail.markOpen(id: id)
        XCTAssertEqual(detail.phase, .closing)
    }

    @MainActor
    func testOrdinaryCourseOpensCorrectDetailAndRejectsRepeat() throws {
        let detail = TimetableCourseDetailCoordinator()
        XCTAssertTrue(detail.open(course: course(), context: context, color: .blue))
        let route = try XCTUnwrap(detail.route)
        XCTAssertEqual(route.course.name, "完整课程名称")
        XCTAssertEqual(route.context, context)
        XCTAssertEqual(detail.phase, .opening)
        XCTAssertTrue(detail.isPresenting)
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
        XCTAssertFalse(detail.isPresenting)
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
        func height(name: String, room: String? = "A101", teacher: String? = "教师",
                    size: DynamicTypeSize, glassHeader: Bool = false) -> CGFloat {
            let view = TimetableDetailContent(course: course(name: name, room: room,
                                                             teacher: teacher), courseColor: .blue,
                                               focusTitle: false, onClose: {},
                                               glassHeader: glassHeader)
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
        XCTAssertGreaterThan(height(name: "机器学习",
                                    room: String(repeating: "教学楼与实验室", count: 8),
                                    teacher: String(repeating: "任课教师", count: 8),
                                    size: .medium), short)
        XCTAssertGreaterThan(height(name: "机器学习", size: .medium, glassHeader: true), short)
    }

    func testInformationRowsKeepFullValuesAndOptionalTeachingWeek() {
        let full = course(name: "Python 数据分析与可视化技术",
                          room: "综合实验楼 A101 与 B202", teacher: "张老师、李老师")
        let rows = TimetableDetailInformation.rows(for: full)
        XCTAssertEqual(rows.map(\.label), ["日期与时间", "教室", "任课教师", "教学周", "节次"])
        XCTAssertEqual(rows[0].value, "2026-09-08 · 08:00–09:35")
        XCTAssertEqual(rows[1].value, full.room ?? "")
        XCTAssertEqual(rows[2].value, full.teacher ?? "")
        XCTAssertEqual(rows[3].value, full.weekExpression ?? "")
        XCTAssertTrue(rows[3].isSecondary)
        XCTAssertEqual(rows[4].value, "第 1–2 节")
        XCTAssertEqual(full.name, "Python 数据分析与可视化技术")

        let noWeek = TimetableDetailInformation.rows(for: course(weeks: nil))
        XCTAssertFalse(noWeek.contains(where: { $0.label == "教学周" }))
    }
}
