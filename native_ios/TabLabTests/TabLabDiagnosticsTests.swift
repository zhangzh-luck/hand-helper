import XCTest
@testable import HandHelperTabLab

@MainActor
final class TabLabDiagnosticsTests: XCTestCase {
    func testTabLabUsesAnonymousTabsOnly() {
        XCTAssertEqual(TabSwitchDiagnosticTab.allCases.map(\.title), ["今日", "课程表", "分析", "设置"])
        XCTAssertEqual(TabSwitchDiagnosticTab.allCases.map(\.symbol), ["house", "calendar", "chart.bar", "gearshape"])
    }
}
