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

/// Routes Settings destinations through the tab controller's temporary overlay stack.
/// The tab controller and its root Settings page remain stationary underneath it.
@MainActor
final class SettingsNavigator: ObservableObject {
    fileprivate weak var overlayHost: NativeTabController?

    func push<Content: View>(title: String, @ViewBuilder content: () -> Content) {
        overlayHost?.pushSettingsDestination(
            title: title,
            content: AnyView(content().environment(\.settingsNavigator, self))
        )
    }

    func pop() {
        overlayHost?.popSettingsDestination()
    }
}

/// The stationary, first-level Settings navigation controller installed as one tab.
/// Secondary Settings pages are intentionally not pushed here: they belong to the
/// overlay navigation controller above the tab bar.
@MainActor
final class SettingsNavigationController: UINavigationController {
    let navigator: SettingsNavigator

    init(state: AppState) {
        let navigator = SettingsNavigator()
        let root = UIHostingController(
            rootView: AnyView(SettingsView(state: state).environment(\.settingsNavigator, navigator))
        )
        root.title = "设置"
        root.navigationItem.largeTitleDisplayMode = .always
        self.navigator = navigator
        super.init(rootViewController: root)
        navigationBar.prefersLargeTitles = true
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(state:)")
    }
}

/// A full-screen navigation stack installed above `UITabBarController.tabBar` only
/// while Settings has a secondary page. Its transparent root keeps the stationary
/// Settings page and tab bar visible during UIKit's interactive pop transition.
@MainActor
final class SettingsOverlayNavigationController: UINavigationController, UINavigationControllerDelegate {
    private let transparentRoot = TransparentSettingsOverlayRootController()
    var becameEmpty: (() -> Void)?

    init() {
        super.init(rootViewController: transparentRoot)
        delegate = self
        view.backgroundColor = .clear
        view.isOpaque = false
        navigationBar.prefersLargeTitles = false
        setNavigationBarHidden(true, animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("Use init()")
    }

    var isTransitioning: Bool {
        transitionCoordinator != nil
    }

    func pushDestination(_ controller: UIViewController) {
        guard !isTransitioning else { return }
        setNavigationBarHidden(false, animated: false)
        pushViewController(controller, animated: true)
    }

    func popDestination() {
        guard viewControllers.count > 1, !isTransitioning else { return }
        popViewController(animated: true)
    }

    func navigationController(_ navigationController: UINavigationController,
                              willShow viewController: UIViewController,
                              animated: Bool) {
        if viewController === transparentRoot {
            setNavigationBarHidden(true, animated: animated)
        } else {
            setNavigationBarHidden(false, animated: animated)
        }
    }

    func navigationController(_ navigationController: UINavigationController,
                              didShow viewController: UIViewController,
                              animated: Bool) {
        // `didShow` resolves to the original detail after an interactive-pop
        // cancellation, so removal here is safe for both completed and cancelled
        // gestures.
        if viewController === transparentRoot {
            becameEmpty?()
        }
    }
}

private final class TransparentSettingsOverlayRootController: UIHostingController<AnyView> {
    init() {
        super.init(rootView: AnyView(Color.clear.ignoresSafeArea()))
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
    }
}

/// Keeps Settings rows visually equivalent to `NavigationLink` while routing their
/// destination through the enclosing UIKit overlay navigation controller.
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
