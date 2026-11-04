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
    case loginFailed
}

enum AppHapticFeedback: Equatable {
    case selection
    case lightImpact
    case mediumImpact
}

enum AppHaptics {
    static func feedback(for interaction: AppHapticInteraction) -> AppHapticFeedback {
        switch interaction {
        case .tabChanged, .discreteSelection:
            .selection
        case .detailOpened, .detailClosed, .settingsNavigation, .cropCompleted:
            .lightImpact
        case .loginFailed:
            .mediumImpact
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
        }
    }
}
