import UIKit

/// Maps the app's small set of intentional interaction milestones to native haptics.
/// System controls retain their own feedback; callers only use this for transitions
/// that SwiftUI/UIKit does not otherwise acknowledge.
enum AppHapticInteraction: CaseIterable {
    case tabChanged
    case discreteSelection
    case detailOpened
    case detailClosed
    case settingsNavigation
    case cropCompleted
    case loginCredentialsRejected
    case loginRequestFailed
}

enum AppHapticFeedback: Equatable {
    case selection
    case lightImpact
    case mediumImpact
    case notificationError
    case notificationWarning
}

enum LoginFailureFeedback: Equatable {
    case credentialsRejected
    case recoverable

    static func classify(_ error: Error) -> Self {
        if case APIError.unauthorized = error { return .credentialsRejected }
        return .recoverable
    }

    var hapticInteraction: AppHapticInteraction {
        switch self {
        case .credentialsRejected: .loginCredentialsRejected
        case .recoverable: .loginRequestFailed
        }
    }
}

struct LoginFailureFeedbackEvent: Identifiable, Equatable {
    let id = UUID()
    let feedback: LoginFailureFeedback
}

enum AppHaptics {
    static func feedback(for interaction: AppHapticInteraction) -> AppHapticFeedback {
        switch interaction {
        case .tabChanged, .discreteSelection:
            .selection
        case .detailOpened, .detailClosed, .settingsNavigation, .cropCompleted:
            .lightImpact
        case .loginCredentialsRejected:
            .notificationError
        case .loginRequestFailed:
            .notificationWarning
        }
    }

    static func trigger(_ interaction: AppHapticInteraction) {
        switch feedback(for: interaction) {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .lightImpact:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .mediumImpact:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .notificationError:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .notificationWarning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
