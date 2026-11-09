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
        XCTAssertEqual(report.p95FrameIntervalMilliseconds, 24)
        XCTAssertEqual(report.intervalsOverTwentyMilliseconds, 1)
        XCTAssertFalse(diagnostics.exportText.localizedCaseInsensitiveContains("cookie"))
        XCTAssertFalse(diagnostics.exportText.localizedCaseInsensitiveContains("account"))
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
}
