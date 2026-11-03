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
        print("SETTINGS_ROW_HEIGHTS: \(rows.map { String(format: "%.1f", $0.frame.height) }.joined(separator: ", "))")
        XCTAssertGreaterThanOrEqual(rows.count, 5)
    }
}

private final class SettingsLayoutSessionStore: SessionStore {
    private(set) var cookie: String?
    func save(cookie: String) { self.cookie = cookie }
    func clear() -> Bool { cookie = nil; return true }
}
