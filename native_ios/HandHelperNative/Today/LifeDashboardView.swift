import SwiftUI

enum LifeDashboardCardText {
    static func expense(_ snapshot: LifeSnapshot?, loading: Bool) -> String {
        guard let snapshot else { return loading ? "正在读取" : "暂无数据" }
        guard snapshot.hasTransactions else { return "暂无记录" }
        return LifeDashboardRules.amount(snapshot.summary.expenseMinor, currency: snapshot.summary.currency)
    }

    static func budget(_ snapshot: LifeSnapshot?, loading: Bool) -> String {
        guard let snapshot else { return loading ? "正在读取" : "暂无数据" }
        guard let remaining = snapshot.summary.remainingMinor else { return "未设置" }
        return LifeDashboardRules.amount(remaining, currency: snapshot.summary.currency)
    }
}

enum LifeDashboardLayout {
    static func useSingleColumn(accessibilitySize: Bool, expense: String, budget: String) -> Bool {
        accessibilitySize || expense.count > 14 || budget.count > 14
    }
}

/// Peer dashboard sections; no surrounding card or business-state ownership.
@MainActor
struct LifeDashboardView: View {
    @ObservedObject var model: LifeDashboardModel
    let onAdd: () -> Void
    let onLedger: () -> Void
    let hasWallpaper: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var currencyInput = "CNY"
    @State private var customCurrency = false
    @State private var unavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            financialSection
            subscriptionSection
            shortcutsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .privacySensitive()
        .alert("输入币种代码", isPresented: $customCurrency) {
            TextField("例如 CNY", text: $currencyInput)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
            Button("查看") { selectCurrency(currencyInput) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("请输入三位币种代码，数据不会进行汇率换算。")
        }
        .alert("暂未开放", isPresented: $unavailable) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("订阅管理将在后续阶段开放。")
        }
    }

    private var financialSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    heading("我的财务")
                    Spacer(minLength: 0)
                    financialControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    heading("我的财务")
                    financialControls
                }
            }
            if model.isCached {
                note("显示本机缓存，可能不是最新数据")
            }
            if LifeDashboardLayout.useSingleColumn(accessibilitySize: dynamicTypeSize.isAccessibilitySize,
                                                  expense: expenseValue, budget: budgetValue) {
                VStack(spacing: 12) { financialCards }
            } else {
                HStack(alignment: .top, spacing: 12) { financialCards }
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Text(error).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("重试") { Task { await model.load(force: true) } }
                        .font(.footnote.weight(.semibold)).disabled(model.isLoading)
                }
                .padding(12).lifeSurface(hasWallpaper: hasWallpaper)
            }
        }
    }

    private var financialControls: some View {
        HStack(spacing: 8) {
            if model.isLoading { ProgressView().controlSize(.small) }
            Text(model.snapshot?.summary.month ?? String(LifeDashboardRules.dateKey(Date()).prefix(7)))
                .font(.subheadline).foregroundStyle(.secondary)
            Menu {
                ForEach(["CNY", "USD", "EUR", "GBP", "HKD", "JPY"], id: \.self) { code in
                    Button(code) { selectCurrency(code) }
                }
                Button("其他币种…") { currencyInput = model.currency; customCurrency = true }
            } label: {
                Label(model.currency, systemImage: "chevron.down")
                    .labelStyle(.titleAndIcon).font(.subheadline.weight(.medium))
            }
            .accessibilityLabel("选择币种，当前\(model.currency)")
            Button { Task { await model.load(force: true) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isLoading)
            .accessibilityLabel("刷新生活数据")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background {
            if hasWallpaper {
                if reduceTransparency || contrast == .increased {
                    Capsule().fill(Color(uiColor: .secondarySystemGroupedBackground))
                } else { Capsule().fill(.regularMaterial) }
            }
        }
    }

    @ViewBuilder
    private var financialCards: some View {
        financialCard("本月支出", value: expenseValue, symbol: "arrow.up.right")
        financialCard("剩余预算", value: budgetValue, symbol: "chart.pie")
    }

    private var expenseValue: String {
        LifeDashboardCardText.expense(model.snapshot, loading: model.isLoading)
    }

    private var budgetValue: String {
        LifeDashboardCardText.budget(model.snapshot, loading: model.isLoading)
    }

    private func financialCard(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(16).lifeSurface(hasWallpaper: hasWallpaper)
        .accessibilityElement(children: .combine)
    }

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("订阅")
            if let snapshot = model.snapshot {
                let items = LifeDashboardRules.upcoming(snapshot.subscriptions, today: LifeDashboardRules.dateKey(Date()))
                if items.isEmpty {
                    Text("暂无待续费订阅").font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).lifeSurface(hasWallpaper: hasWallpaper)
                } else {
                    ForEach(Array(items.prefix(3))) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.name).font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("续费日期：\(item.nextDueDate)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(LifeDashboardRules.amount(item.amountMinor, currency: item.currency))
                                .font(.subheadline.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).lifeSurface(hasWallpaper: hasWallpaper)
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                Text(model.isLoading ? "正在读取订阅" : "订阅数据暂不可用")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).lifeSurface(hasWallpaper: hasWallpaper)
            }
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("快捷操作")
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) { shortcutButtons }
            } else {
                HStack(alignment: .top, spacing: 12) { shortcutButtons }
            }
        }
    }

    @ViewBuilder
    private var shortcutButtons: some View {
        shortcut("记一笔", symbol: "plus.circle", action: onAdd)
        shortcut("账本", symbol: "list.bullet.rectangle", action: onLedger)
        shortcut("订阅管理", symbol: "calendar.badge.clock") { unavailable = true }
    }

    private func shortcut(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(12).lifeSurface(hasWallpaper: hasWallpaper)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(title == "订阅管理" ? "此功能尚未开放" : "")
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
            .padding(.horizontal, hasWallpaper ? 8 : 0).padding(.vertical, hasWallpaper ? 4 : 0)
            .background {
                if hasWallpaper {
                    if reduceTransparency || contrast == .increased {
                        Capsule().fill(Color(uiColor: .secondarySystemGroupedBackground))
                    } else { Capsule().fill(.regularMaterial) }
                }
            }
            .accessibilityAddTraits(.isHeader)
    }

    private func note(_ value: String) -> some View {
        Text(value).font(.caption).foregroundStyle(.secondary)
            .padding(8).lifeSurface(hasWallpaper: hasWallpaper)
    }

    private func selectCurrency(_ code: String) {
        Task { await model.selectCurrency(code) }
    }
}

private struct LifeSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let hasWallpaper: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return content.background {
            if hasWallpaper && !reduceTransparency && contrast != .increased {
                shape.fill(.regularMaterial)
            } else {
                shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
            }
        }
    }
}

private extension View {
    func lifeSurface(hasWallpaper: Bool) -> some View {
        modifier(LifeSurface(hasWallpaper: hasWallpaper))
    }
}
