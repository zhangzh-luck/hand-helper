import Combine
import UIKit

@main
final class TabLabAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = TabLabSceneDelegate.self
        return configuration
    }
}

final class TabLabSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: TabLabRootController())
        window.makeKeyAndVisible()
        self.window = window
    }
}

private enum TabLabMode: Int {
    case tabBarController, standaloneTabBar

    var title: String {
        switch self {
        case .tabBarController: "模式 A：UITabBarController"
        case .standaloneTabBar: "模式 B：独立 UITabBar"
        }
    }
}

private final class TabLabRootController: UIViewController {
    private let diagnostics = TabSwitchDiagnostics()
    private let modeControl = UISegmentedControl(items: ["模式 A", "模式 B"])
    private let enabledSwitch = UISwitch()
    private let modeDescription = UILabel()
    private let container = UIView()
    private var activeController: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Hand Helper Tab Lab"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "诊断", style: .plain,
                                                             target: self, action: #selector(showDiagnostics))

        modeControl.selectedSegmentIndex = 0
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeDescription.font = .preferredFont(forTextStyle: .footnote)
        modeDescription.textColor = .secondaryLabel
        modeDescription.numberOfLines = 0

        let enabledLabel = UILabel()
        enabledLabel.text = "记录 Tab 切换性能"
        let enabledRow = UIStackView(arrangedSubviews: [enabledLabel, UIView(), enabledSwitch])
        enabledRow.alignment = .center
        enabledSwitch.isOn = diagnostics.isEnabled
        enabledSwitch.addTarget(self, action: #selector(diagnosticsEnabledChanged), for: .valueChanged)

        let header = UIStackView(arrangedSubviews: [modeControl, modeDescription, enabledRow])
        header.axis = .vertical
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(container)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            container.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        installMode(.tabBarController)
    }

    @objc private func modeChanged() {
        installMode(TabLabMode(rawValue: modeControl.selectedSegmentIndex) ?? .tabBarController)
    }

    @objc private func diagnosticsEnabledChanged() {
        diagnostics.setEnabled(enabledSwitch.isOn)
    }

    @objc private func showDiagnostics() {
        navigationController?.pushViewController(TabLabDiagnosticsController(diagnostics: diagnostics), animated: true)
    }

    private func installMode(_ mode: TabLabMode) {
        modeDescription.text = mode.title + "。仅使用静态 UIKit 页面，不读取业务数据。"
        diagnostics.setReportContext(mode.title)
        activeController?.willMove(toParent: nil)
        activeController?.view.removeFromSuperview()
        activeController?.removeFromParent()
        let controller: UIViewController
        switch mode {
        case .tabBarController: controller = TabLabTabBarController(diagnostics: diagnostics)
        case .standaloneTabBar: controller = TabLabStandaloneHostController(diagnostics: diagnostics)
        }
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: container.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        controller.didMove(toParent: self)
        activeController = controller
    }
}

private final class TabLabTabBarController: UITabBarController, UITabBarControllerDelegate {
    private let diagnostics: TabSwitchDiagnostics

    init(diagnostics: TabSwitchDiagnostics) {
        self.diagnostics = diagnostics
        super.init(nibName: nil, bundle: nil)
        viewControllers = TabSwitchDiagnosticTab.allCases.map { tab in
            let controller = TabLabPageController(tab: tab, diagnostics: diagnostics)
            controller.tabBarItem = UITabBarItem(title: nil, image: UIImage(systemName: tab.symbol), tag: tab.rawValue)
            controller.tabBarItem.accessibilityLabel = tab.title
            return controller
        }
        delegate = self
        configureAppearance()
    }

    required init?(coder: NSCoder) { fatalError("Use init(diagnostics:)") }

    private func configureAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        for itemAppearance in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance,
                               appearance.compactInlineLayoutAppearance] {
            itemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.clear]
            itemAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.clear]
        }
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = .systemBlue
    }

    func tabBarController(_ tabBarController: UITabBarController,
                          shouldSelect viewController: UIViewController) -> Bool {
        guard let destinationIndex = viewControllers?.firstIndex(where: { $0 === viewController }),
              let destination = TabSwitchDiagnosticTab(rawValue: destinationIndex),
              let source = TabSwitchDiagnosticTab(rawValue: selectedIndex) else { return true }
        diagnostics.beginSwitch(from: source, to: destination, screen: view.window?.screen)
        return true
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        guard let destination = TabSwitchDiagnosticTab(rawValue: selectedIndex) else { return }
        diagnostics.recordSelectionApplied(for: destination)
        diagnostics.recordStateApplied(for: destination)
    }
}

private final class TabLabStandaloneHostController: UIViewController, UITabBarDelegate {
    private let diagnostics: TabSwitchDiagnostics
    private let tabBar = TabLabBareTabBar()
    private let content = TabLabPageController(tab: .today, diagnostics: nil)
    private var selected = TabSwitchDiagnosticTab.today

    init(diagnostics: TabSwitchDiagnostics) {
        self.diagnostics = diagnostics
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(diagnostics:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content.view)
        content.didMove(toParent: self)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        tabBar.items = TabSwitchDiagnosticTab.allCases.map { tab in
            let item = UITabBarItem(title: nil, image: UIImage(systemName: tab.symbol), tag: tab.rawValue)
            item.accessibilityLabel = tab.title
            return item
        }
        tabBar.selectedItem = tabBar.items?.first
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        for itemAppearance in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance,
                               appearance.compactInlineLayoutAppearance] {
            itemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.clear]
            itemAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.clear]
        }
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = .systemBlue
        tabBar.willSelect = { [weak self] index in self?.beginTouchSelection(index: index) }
        view.addSubview(tabBar)
        NSLayoutConstraint.activate([
            content.view.topAnchor.constraint(equalTo: view.topAnchor),
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func beginTouchSelection(index: Int) {
        guard let destination = TabSwitchDiagnosticTab(rawValue: index) else { return }
        diagnostics.beginSwitch(from: selected, to: destination, screen: view.window?.screen)
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard let destination = TabSwitchDiagnosticTab(rawValue: item.tag) else { return }
        if destination != selected {
            selected = destination
            content.apply(tab: destination)
        }
        diagnostics.recordSelectionApplied(for: destination)
        diagnostics.recordStateApplied(for: destination)
        diagnostics.recordPageReady(for: destination, cacheState: .retained)
    }
}

/// A public UIKit touch override lets mode B start its timer before the tab bar commits selection.
private final class TabLabBareTabBar: UITabBar {
    var willSelect: ((Int) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let point = touches.first?.location(in: self), bounds.width > 0 {
            let index = min(TabSwitchDiagnosticTab.allCases.count - 1,
                            max(0, Int(point.x / (bounds.width / CGFloat(TabSwitchDiagnosticTab.allCases.count)))))
            willSelect?(index)
        }
        super.touchesBegan(touches, with: event)
    }
}

private final class TabLabPageController: UIViewController {
    private let titleLabel = UILabel()
    private var diagnosticTab: TabSwitchDiagnosticTab
    private weak var diagnostics: TabSwitchDiagnostics?

    init(tab: TabSwitchDiagnosticTab, diagnostics: TabSwitchDiagnostics?) {
        self.diagnosticTab = tab
        self.diagnostics = diagnostics
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(tab:diagnostics:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        apply(tab: diagnosticTab)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        diagnostics?.recordPageReady(for: diagnosticTab, cacheState: .retained)
    }

    func apply(tab: TabSwitchDiagnosticTab) {
        self.diagnosticTab = tab
        titleLabel.text = tab.title
        let colors: [UIColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple]
        view.backgroundColor = colors[tab.rawValue].withAlphaComponent(0.16)
    }
}

private final class TabLabDiagnosticsController: UIViewController {
    private let diagnostics: TabSwitchDiagnostics
    private let textView = UITextView()
    private var observation: AnyCancellable?

    init(diagnostics: TabSwitchDiagnostics) {
        self.diagnostics = diagnostics
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(diagnostics:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Tab Lab 诊断"
        view.backgroundColor = .systemBackground
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isEditable = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "复制", style: .plain, target: self, action: #selector(copyReport)),
            UIBarButtonItem(title: "清除", style: .plain, target: self, action: #selector(clearReport))
        ]
        observation = diagnostics.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    @objc private func copyReport() { UIPasteboard.general.string = diagnostics.exportText }
    @objc private func clearReport() { diagnostics.clearReports(); refresh() }

    private func refresh() {
        textView.text = diagnostics.reports.isEmpty
            ? "暂无记录。返回后开启记录并切换 Tab。"
            : diagnostics.exportText
    }
}
