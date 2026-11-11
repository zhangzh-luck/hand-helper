import XCTest
@testable import HandHelperNative

final class FloatingLabelStateTests: XCTestCase {
    func testEmptyUnfocusedFieldKeepsLabelInside() {
        XCTAssertFalse(FloatingLabelState.shouldFloat(text: "", isFocused: false))
    }

    func testFocusedFieldFloatsEmptyLabel() {
        XCTAssertTrue(FloatingLabelState.shouldFloat(text: "", isFocused: true))
    }

    func testFilledUnfocusedFieldKeepsLabelFloated() {
        XCTAssertTrue(FloatingLabelState.shouldFloat(text: "student", isFocused: false))
    }

    func testClearingAfterFocusLossReturnsLabelInside() {
        XCTAssertFalse(FloatingLabelState.shouldFloat(text: "", isFocused: false))
    }

    func testLoginButtonUsesAvailableWidthWhenIdle() {
        XCTAssertEqual(
            LoginButtonPresentation.width(isSubmitting: false, availableWidth: 320),
            320
        )
        XCTAssertEqual(LoginButtonPresentation.cornerRadius(isSubmitting: false), 18)
    }

    func testLoginButtonShrinksToFixedCircleWhenSubmitting() {
        XCTAssertEqual(
            LoginButtonPresentation.width(isSubmitting: true, availableWidth: 320),
            56
        )
        XCTAssertEqual(LoginButtonPresentation.cornerRadius(isSubmitting: true), 28)
    }
}
