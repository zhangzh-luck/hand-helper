import XCTest
@testable import HandHelperNative

final class HapticFeedbackTests: XCTestCase {
    func testInteractionMappingsMatchNativeFeedbackSemantics() {
        XCTAssertEqual(AppHaptics.feedback(for: .tabChanged), .selection)
        XCTAssertEqual(AppHaptics.feedback(for: .discreteSelection), .selection)
        XCTAssertEqual(AppHaptics.feedback(for: .detailOpened), .lightImpact)
        XCTAssertEqual(AppHaptics.feedback(for: .detailClosed), .lightImpact)
        XCTAssertEqual(AppHaptics.feedback(for: .settingsNavigation), .lightImpact)
        XCTAssertEqual(AppHaptics.feedback(for: .cropCompleted), .lightImpact)
        XCTAssertEqual(AppHaptics.feedback(for: .loginFailed), .mediumImpact)
    }
}
