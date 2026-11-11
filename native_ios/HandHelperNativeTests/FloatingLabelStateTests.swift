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
}
