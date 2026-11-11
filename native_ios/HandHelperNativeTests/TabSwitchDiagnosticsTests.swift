import XCTest
@testable import HandHelperNative

@MainActor
final class TabSwitchDiagnosticsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TabSwitchDiagnosticsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        if let suiteName { defaults.removePersistentDomain(forName: suiteName) }
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDisabledDiagnosticsDoNotCreateReport() {
        let diagnostics = TabSwitchDiagnostics(preferences: defaults, samplesFrames: false)
        diagnostics.beginSwitch(from: .today, to: .timetable, screen: nil)
        diagnostics.recordSelectionApplied(for: .timetable)
        diagnostics.recordTodayDerivedCacheHit()
        diagnostics.recordNativeContainerUpdate(for: .timetable)
        diagnostics.recordNativeApply(changes: [.selectedTab], for: .timetable)
        diagnostics.finishForTesting()

        XCTAssertTrue(diagnostics.reports.isEmpty)
    }

    func testEnabledDiagnosticsContainOnlyTimingAndTabMetadata() {
        var uptime: TimeInterval = 100
        let diagnostics = TabSwitchDiagnostics(preferences: defaults, now: { uptime }, samplesFrames: false)
        diagnostics.setEnabled(true)
        diagnostics.beginSwitch(from: .today, to: .analysis, screen: nil)

        uptime += 0.006
        diagnostics.recordSelectionApplied(for: .analysis)
        uptime += 0.004
        diagnostics.recordStateApplied(for: .analysis)
        uptime += 0.010
        diagnostics.recordPageReady(for: .analysis, cacheState: .hit)
        uptime += 0.003
        diagnostics.recordFirstFrameForTesting()
        diagnostics.recordFrameIntervalForTesting(0.008)
        diagnostics.recordFrameIntervalForTesting(0.024)
        uptime += 0.680
        diagnostics.finishForTesting()

        let report = try! XCTUnwrap(diagnostics.reports.first)
        XCTAssertEqual(report.source, .today)
        XCTAssertEqual(report.destination, .analysis)
        XCTAssertEqual(report.tapToSelectionMilliseconds, 6)
        XCTAssertEqual(report.tapToStateAppliedMilliseconds, 10)
        XCTAssertEqual(report.tapToPageReadyMilliseconds, 20)
        XCTAssertEqual(report.cacheState, .hit)
        XCTAssertEqual(report.frameCount, 2)
        XCTAssertEqual(report.maxFrameIntervalMilliseconds, 24)
        XCTAssertEqual(report.tapToFirstFrameCallbackMilliseconds, 23)
        XCTAssertNil(report.p95FrameIntervalMilliseconds)
        XCTAssertEqual(report.intervalsOverTwentyMilliseconds, 1)
        XCTAssertFalse(diagnostics.exportText.localizedCaseInsensitiveContains("cookie"))
        XCTAssertFalse(diagnostics.exportText.localizedCaseInsensitiveContains("account"))
    }

    func testTimelineUsesOneSwitchIdentifierAndMonotonicOffsets() throws {
        var uptime: TimeInterval = 100
        let diagnostics = TabSwitchDiagnostics(preferences: defaults, now: { uptime }, samplesFrames: false)
        diagnostics.setEnabled(true)
        diagnostics.beginSwitch(from: .today, to: .timetable, screen: nil)
        uptime += 0.003
        diagnostics.record(.didSelect, for: .timetable)
        uptime += 0.004
        diagnostics.record(.timetableTaskCreated, for: .timetable)
        uptime += 0.006
        diagnostics.record(.timetableTaskStarted, for: .timetable)
        diagnostics.finishForTesting()

        let report = try XCTUnwrap(diagnostics.reports.first)
        XCTAssertEqual(report.events.map(\.stage), [.shouldSelect, .didSelect,
                                                     .timetableTaskCreated, .timetableTaskStarted])
        XCTAssertEqual(report.events.map(\.offsetMilliseconds), [0, 3, 7, 13])
        XCTAssertTrue(report.exportLine.contains("switch_id="))
    }

    func testActiveSwitchMilestonesCanDescribeRetainedSourceWork() throws {
        var uptime: TimeInterval = 100
        let diagnostics = TabSwitchDiagnostics(preferences: defaults, now: { uptime }, samplesFrames: false)
        diagnostics.setEnabled(true)
        diagnostics.beginSwitch(from: .today, to: .settings, screen: nil)
        diagnostics.recordForActiveSwitch(.avatarPreviewClearSkipped)
        diagnostics.recordTodayDerivedCacheHit()
        diagnostics.recordTodayDerivedCacheHit()
        diagnostics.beginTodayDerivedCacheRebuild()
        uptime += 0.007
        diagnostics.endTodayDerivedCacheRebuild()
        diagnostics.finishForTesting()

        let report = try XCTUnwrap(diagnostics.reports.first)
        let stages = report.events.map(\.stage)
        XCTAssertEqual(stages, [.shouldSelect, .avatarPreviewClearSkipped])
        XCTAssertEqual(report.todayDerivedCacheHitCount, 2)
        XCTAssertEqual(report.todayDerivedCacheRebuildCount, 1)
        XCTAssertEqual(report.todayDerivedCacheRebuildTotalMilliseconds, 7)
    }

    func testNativeContainerCountersSeparateEffectiveAndNoOpApplyCalls() throws {
        let diagnostics = TabSwitchDiagnostics(preferences: defaults, samplesFrames: false)
        diagnostics.setEnabled(true)
        diagnostics.beginSwitch(from: .today, to: .settings, screen: nil)

        diagnostics.recordNativeContainerUpdate(for: .settings)
        diagnostics.recordNativeApply(changes: [.selectedTab, .appearance], for: .settings)
        diagnostics.recordNativeContainerUpdate(for: .settings)
        diagnostics.recordNativeApply(changes: [], for: .settings)
        diagnostics.recordKnownStateChange(.selectedTab, for: .settings)
        diagnostics.recordKnownStateChangeForActiveSwitch(.avatarPreview)
        diagnostics.finishForTesting()

        let report = try XCTUnwrap(diagnostics.reports.first)
        XCTAssertEqual(report.nativeContainerUpdateCount, 2)
        XCTAssertEqual(report.nativeApplyCallCount, 2)
        XCTAssertEqual(report.nativeApplyEffectiveChangeCount, 1)
        XCTAssertEqual(report.nativeApplyNoOpCount, 1)
        XCTAssertEqual(Set(report.nativeApplyChanges), Set([.selectedTab, .appearance]))
        XCTAssertEqual(Set(report.knownStateChanges), Set([.selectedTab, .avatarPreview]))
        XCTAssertTrue(report.exportLine.contains("native_apply_noop=1"))
    }

    func testAggregatesRemainBoundToTheActiveSwitchIdentifier() throws {
        let diagnostics = TabSwitchDiagnostics(preferences: defaults, samplesFrames: false)
        diagnostics.setEnabled(true)
        diagnostics.beginSwitch(from: .today, to: .timetable, screen: nil)
        diagnostics.recordTodayDerivedCacheHit()
        diagnostics.recordNativeContainerUpdate(for: .timetable)
        diagnostics.beginSwitch(from: .timetable, to: .analysis, screen: nil)
        diagnostics.recordNativeApply(changes: [.selectedTab], for: .analysis)
        diagnostics.finishForTesting()

        XCTAssertEqual(diagnostics.reports.count, 2)
        let current = try XCTUnwrap(diagnostics.reports.first)
        let interrupted = try XCTUnwrap(diagnostics.reports.last)
        XCTAssertEqual(current.destination, .analysis)
        XCTAssertEqual(current.todayDerivedCacheHitCount, 0)
        XCTAssertEqual(current.nativeApplyEffectiveChangeCount, 1)
        XCTAssertEqual(interrupted.destination, .timetable)
        XCTAssertTrue(interrupted.interrupted)
        XCTAssertEqual(interrupted.todayDerivedCacheHitCount, 1)
        XCTAssertEqual(interrupted.nativeContainerUpdateCount, 1)
    }

    func testReplacementSwitchMarksPreviousSampleInterrupted() {
        let diagnostics = TabSwitchDiagnostics(preferences: defaults, samplesFrames: false)
        diagnostics.setEnabled(true)
        diagnostics.beginSwitch(from: .today, to: .timetable, screen: nil)
        diagnostics.beginSwitch(from: .timetable, to: .analysis, screen: nil)

        XCTAssertEqual(diagnostics.reports.count, 1)
        XCTAssertTrue(diagnostics.reports[0].interrupted)
        XCTAssertEqual(diagnostics.reports[0].destination, .timetable)
    }

    func testP95RequiresTenIntervals() {
        let diagnostics = TabSwitchDiagnostics(preferences: defaults, samplesFrames: false)
        diagnostics.setEnabled(true)
        diagnostics.beginSwitch(from: .today, to: .analysis, screen: nil)
        for _ in 0..<10 { diagnostics.recordFrameIntervalForTesting(0.008) }
        diagnostics.recordFrameIntervalForTesting(0.024)
        diagnostics.finishForTesting()

        XCTAssertEqual(diagnostics.reports.first?.p95FrameIntervalMilliseconds, 24)
    }

    func testDisablingFinishesActiveSampleAndStopsFutureRecording() {
        let diagnostics = TabSwitchDiagnostics(preferences: defaults, samplesFrames: false)
        diagnostics.setEnabled(true)
        diagnostics.beginSwitch(from: .today, to: .settings, screen: nil)
        diagnostics.setEnabled(false)

        XCTAssertFalse(diagnostics.isEnabled)
        XCTAssertFalse(diagnostics.isSampling)
        XCTAssertEqual(diagnostics.reports.count, 1)
        diagnostics.beginSwitch(from: .settings, to: .today, screen: nil)
        XCTAssertEqual(diagnostics.reports.count, 1)
    }

    func testReportsAndAggregateCountersAreNotPersisted() throws {
        let diagnostics = TabSwitchDiagnostics(preferences: defaults, samplesFrames: false)
        diagnostics.setEnabled(true)
        diagnostics.beginSwitch(from: .today, to: .settings, screen: nil)
        diagnostics.recordTodayDerivedCacheHit()
        diagnostics.recordNativeApply(changes: [.selectedTab], for: .settings)
        diagnostics.finishForTesting()

        let report = try XCTUnwrap(diagnostics.reports.first)
        XCTAssertEqual(report.todayDerivedCacheHitCount, 1)
        let reloaded = TabSwitchDiagnostics(preferences: defaults, samplesFrames: false)
        XCTAssertTrue(reloaded.reports.isEmpty)
        XCTAssertTrue(reloaded.isEnabled) // The explicit opt-in is the sole persisted diagnostic value.
    }
}
