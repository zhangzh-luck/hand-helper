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
        guard rows.count >= 5 else { XCTFail("Missing settings list cells"); return }
        let functionRows = Array(rows[1...3])
        for row in functionRows {
            XCTAssertGreaterThanOrEqual(row.frame.height, 56)
            XCTAssertLessThanOrEqual(row.frame.height, 60)
        }
        for index in 1..<functionRows.count {
            let gap = functionRows[index].frame.minY - functionRows[index - 1].frame.maxY
            XCTAssertLessThanOrEqual(abs(gap), 1, "Separators should sit at adjacent row boundaries")
        }
        let groupHeight = functionRows[2].frame.maxY - functionRows[0].frame.minY
        print("SETTINGS_FUNCTION_GROUP_HEIGHT: \(String(format: "%.1f", groupHeight))")
        let accountToFunctions = functionRows[0].frame.minY - rows[0].frame.maxY
        let functionsToAbout = rows[4].frame.minY - functionRows[2].frame.maxY
        print("SETTINGS_SECTION_GAPS: account=\(String(format: "%.1f", accountToFunctions)) about=\(String(format: "%.1f", functionsToAbout))")
        XCTAssertEqual(groupHeight, 168, accuracy: 0.5)
    }
}

private final class SettingsLayoutSessionStore: SessionStore {
    private(set) var cookie: String?
    func save(cookie: String) { self.cookie = cookie }
    func clear() -> Bool { cookie = nil; return true }
}
