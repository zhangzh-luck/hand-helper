import SwiftUI
import UIKit

private struct SettingsNavigatorKey: EnvironmentKey {
    static let defaultValue: SettingsNavigator? = nil
}

extension EnvironmentValues {
    var settingsNavigator: SettingsNavigator? {
        get { self[SettingsNavigatorKey.self] }
        set { self[SettingsNavigatorKey.self] = newValue }
    }
}

/// Routes Settings destinations through UIKit so a pushed host can participate in the
/// tab controller's native `hidesBottomBarWhenPushed` and interactive-pop lifecycle.
@MainActor
final class SettingsNavigator: ObservableObject {
    fileprivate weak var navigationController: SettingsNavigationController?

    func push<Content: View>(title: String, @ViewBuilder content: () -> Content) {
        guard let navigationController else { return }
        let host = UIHostingController(
            rootView: AnyView(content().environment(\.settingsNavigator, self))
        )
        host.title = title
        host.navigationItem.largeTitleDisplayMode = .never
        host.hidesBottomBarWhenPushed = true
        navigationController.pushViewController(host, animated: true)
    }

    func pop() {
        navigationController?.popViewController(animated: true)
    }
}

@MainActor
final class SettingsNavigationController: UINavigationController, UINavigationControllerDelegate {
    let navigator: SettingsNavigator
    var stackVisibilityDidChange: (() -> Void)?

    init(state: AppState) {
        let navigator = SettingsNavigator()
        let root = UIHostingController(
            rootView: AnyView(SettingsView(state: state).environment(\.settingsNavigator, navigator))
        )
        root.title = "设置"
        root.navigationItem.largeTitleDisplayMode = .always
        self.navigator = navigator
        super.init(rootViewController: root)
        navigator.navigationController = self
        delegate = self
        navigationBar.prefersLargeTitles = true
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(state:)")
    }

    var isShowingSecondaryPage: Bool {
        viewControllers.count > 1
    }

    func navigationController(_ navigationController: UINavigationController,
                              didShow viewController: UIViewController,
                              animated: Bool) {
        stackVisibilityDidChange?()
    }
}

/// Keeps settings rows visually equivalent to `NavigationLink` while routing their
/// destination through the enclosing UIKit navigation controller.
struct SettingsNavigationButton<Label: View>: View {
    let action: () -> Void
    private let label: Label

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button {
            AppHaptics.trigger(.settingsNavigation)
            action()
        } label: {
            HStack(spacing: 12) {
                label
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
