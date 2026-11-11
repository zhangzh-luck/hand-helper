import SwiftUI
import UIKit
import XCTest
@testable import HandHelperNative

final class SettingsLayoutTests: XCTestCase {
    @MainActor
    func testMeasuredSettingsRows() {
        let state = AppState(api: MockAPIClient(), sessionStore: SettingsLayoutSessionStore())
        let host = UIHostingController(rootView: SettingsView(state: state))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.view.layoutIfNeeded()

        func collections(in view: UIView) -> [UICollectionView] {
            let current = (view as? UICollectionView).map { [$0] } ?? []
            return current + view.subviews.flatMap { collections(in: $0) }
        }
        let rows = collections(in: host.view).flatMap(\.visibleCells)
            .sorted { $0.frame.minY < $1.frame.minY }
        let rowFrames = rows.map {
            String(format: "y=%.1f h=%.1f", $0.frame.minY, $0.frame.height)
        }.joined(separator: ", ")
        print("SETTINGS_ROW_FRAMES: \(rowFrames)")
        guard rows.count >= 6 else { XCTFail("Missing settings list cells"); return }
        let preferenceRows = Array(rows[1...2])
        let dataAndAssistantRows = Array(rows[3...5])
        for row in preferenceRows + dataAndAssistantRows {
            XCTAssertGreaterThanOrEqual(row.frame.height, 56)
            XCTAssertLessThanOrEqual(row.frame.height, 60)
        }
        for group in [preferenceRows, dataAndAssistantRows] {
            for index in 1..<group.count {
                let gap = group[index].frame.minY - group[index - 1].frame.maxY
                XCTAssertLessThanOrEqual(abs(gap), 1, "Separators should sit at adjacent row boundaries")
            }
        }
        let preferenceHeight = preferenceRows[1].frame.maxY - preferenceRows[0].frame.minY
        let dataAndAssistantHeight = dataAndAssistantRows[2].frame.maxY - dataAndAssistantRows[0].frame.minY
        XCTAssertEqual(preferenceHeight, 112, accuracy: 0.5)
        XCTAssertEqual(dataAndAssistantHeight, 168, accuracy: 0.5)
        let accountToPreferences = preferenceRows[0].frame.minY - rows[0].frame.maxY
        let preferencesToDataAndAssistant = dataAndAssistantRows[0].frame.minY - preferenceRows[1].frame.maxY
        XCTAssertGreaterThan(accountToPreferences, 0)
        XCTAssertGreaterThan(preferencesToDataAndAssistant, 0)
    }
}

private final class SettingsLayoutSessionStore: SessionStore {
    private(set) var cookie: String?
    func save(cookie: String) { self.cookie = cookie }
    func clear() -> Bool { cookie = nil; return true }
}
