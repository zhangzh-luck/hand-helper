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
        XCTAssertEqual(AppHaptics.feedback(for: .loginCredentialsRejected), .notificationError)
        XCTAssertEqual(AppHaptics.feedback(for: .loginRequestFailed), .notificationWarning)
    }

    func testLoginFailureClassificationSeparatesCredentialsFromRecoverableFailures() {
        XCTAssertEqual(LoginFailureFeedback.classify(APIError.unauthorized(message: "用户名或密码错误")),
                       .credentialsRejected)
        XCTAssertEqual(LoginFailureFeedback.classify(APIError.timeout), .recoverable)
        XCTAssertEqual(LoginFailureFeedback.classify(APIError.connection), .recoverable)
        XCTAssertEqual(LoginFailureFeedback.classify(APIError.server(status: 500, message: "服务异常")),
                       .recoverable)
        XCTAssertEqual(LoginFailureFeedback.classify(APIError.invalidResponse), .recoverable)
    }

    func testLoginFailureEventsHaveDistinctIDsForSeparateConfirmedFailures() {
        XCTAssertNotEqual(LoginFailureFeedbackEvent(feedback: .credentialsRejected).id,
                          LoginFailureFeedbackEvent(feedback: .credentialsRejected).id)
    }
}
