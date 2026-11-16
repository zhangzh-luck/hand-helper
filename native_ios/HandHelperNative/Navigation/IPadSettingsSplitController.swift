import UIKit

/// First-stage layout prototype. Destinations deliberately do not access settings data.
enum IPadSettingsCategory: Int, CaseIterable {
    case account, academicTime, personalization, dataImport, ai, about

    var title: String {
        switch self {
        case .account: "账户设置"
        case .academicTime: "时间设置"
        case .personalization: "个性化"
        case .dataImport: "数据与导入"
        case .ai: "AI 模型配置"
        case .about: "关于航的助手"
        }
    }

    var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        case .academicTime: "clock"
        case .personalization: "paintpalette"
        case .dataImport: "square.and.arrow.down"
        case .ai: "sparkles"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class IPadSettingsSplitController: UISplitViewController {
    private let categories = IPadSettingsCategoryListController()
    private(set) var selectedCategory: IPadSettingsCategory?

    init() {
        super.init(style: .doubleColumn)
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        let primary = UINavigationController(rootViewController: categories)
        primary.navigationBar.prefersLargeTitles = true
        setViewController(primary, for: .primary)
        setViewController(UINavigationController(rootViewController: makePlaceholder(nil)), for: .secondary)
        categories.didSelect = { [weak self] category in self?.select(category) }
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func select(_ category: IPadSettingsCategory) {
        selectedCategory = category
        categories.selectedCategory = category
        showDetailViewController(makePlaceholder(category), sender: categories)
    }

    private func makePlaceholder(_ category: IPadSettingsCategory?) -> UIViewController {
        let controller = UIViewController()
        controller.title = category?.title ?? "设置"
        controller.view.backgroundColor = .systemGroupedBackground
        let label = UILabel()
        label.text = category.map { "\($0.title)\n详情将在后续阶段接入" } ?? "请选择设置分类"
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: controller.view.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: controller.view.layoutMarginsGuide.trailingAnchor)
        ])
        return controller
    }
}

@MainActor
private final class IPadSettingsCategoryListController: UITableViewController {
    var didSelect: ((IPadSettingsCategory) -> Void)?
    var selectedCategory: IPadSettingsCategory? { didSet { tableView.reloadData() } }
    private let groups: [[IPadSettingsCategory]] = [
        [.account], [.academicTime, .personalization], [.dataImport, .ai, .about]
    ]
    private let groupTitles = ["账户", "偏好设置", "数据与助手"]

    init() {
        super.init(style: .insetGrouped)
        title = "设置"
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }
    override func numberOfSections(in tableView: UITableView) -> Int { groups.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { groups[section].count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { groupTitles[section] }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let category = groups[indexPath.section][indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "category") ?? UITableViewCell(style: .default, reuseIdentifier: "category")
        var content = cell.defaultContentConfiguration()
        content.text = category.title
        content.image = UIImage(systemName: category.symbol)
        content.imageProperties.tintColor = .systemBlue
        cell.contentConfiguration = content
        cell.accessoryType = selectedCategory == category ? .checkmark : .disclosureIndicator
        cell.accessibilityTraits = selectedCategory == category ? [.button, .selected] : .button
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        didSelect?(groups[indexPath.section][indexPath.row])
    }
}
