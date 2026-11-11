import XCTest
import UIKit
@testable import HandHelperTabLab

@MainActor
final class TabLabDiagnosticsTests: XCTestCase {
    func testTabLabUsesAnonymousTabsOnly() {
        XCTAssertEqual(TabSwitchDiagnosticTab.allCases.map(\.title), ["今日", "课程表", "分析", "设置"])
        XCTAssertEqual(TabSwitchDiagnosticTab.allCases.map(\.symbol), ["house", "calendar", "chart.bar", "gearshape"])
    }

    func testStandaloneTabBarCreatesReportFromDidSelectOnlyForChangedTab() {
        let suiteName = "TabLabDiagnosticsTests.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let diagnostics = TabSwitchDiagnostics(preferences: preferences, samplesFrames: false)
        diagnostics.setEnabled(true)
        let host = TabLabStandaloneHostController(diagnostics: diagnostics)
        host.loadViewIfNeeded()
        let analysis = UITabBarItem(title: nil, image: nil, tag: TabSwitchDiagnosticTab.analysis.rawValue)

        host.tabBar(UITabBar(), didSelect: analysis)
        diagnostics.finishForTesting()

        XCTAssertEqual(diagnostics.reports.count, 1)
        XCTAssertEqual(diagnostics.reports.first?.source, .today)
        XCTAssertEqual(diagnostics.reports.first?.destination, .analysis)
        XCTAssertNotNil(diagnostics.reports.first?.tapToSelectionMilliseconds,
                        "Mode B records selection timing from its didSelect sampling boundary")

        host.tabBar(UITabBar(), didSelect: analysis)
        XCTAssertEqual(diagnostics.reports.count, 1, "Re-selecting the active tab must not create a diagnostic sample")
    }
}
