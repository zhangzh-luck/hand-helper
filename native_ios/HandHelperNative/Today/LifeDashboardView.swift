import SwiftUI

@MainActor
struct LifeDashboardView: View {
    @ObservedObject var model: LifeDashboardModel
    let onAdd: () -> Void
    let onLedger: () -> Void
    @State private var currencyInput = "CNY"
    @State private var unavailable: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("生活概览").font(.headline)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button("刷新") { Task { await model.load(force: true) } }
                    .disabled(model.isLoading)
            }
            HStack {
                Text("币种").font(.subheadline)
                TextField("例如 CNY", text: $currencyInput)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.subheadline.monospaced())
                    .frame(width: 72)
                    .accessibilityLabel("币种代码")
                    .onSubmit { applyCurrency() }
                Button("查看") { applyCurrency() }
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            Text("按币种分别查看，不进行汇率换算。")
                .font(.caption).foregroundStyle(.secondary)

            if let snapshot = model.snapshot {
                if model.isCached {
                    Text("显示本机缓存，可能不是最新数据")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if snapshot.hasTransactions {
                    amountRow("本月收入", snapshot.summary.incomeMinor, snapshot.summary.currency)
                    amountRow("本月支出", snapshot.summary.expenseMinor, snapshot.summary.currency)
                } else {
                    Text("本月暂无 \(snapshot.summary.currency) 交易记录")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let remaining = snapshot.summary.remainingMinor {
                    amountRow("剩余预算", remaining, snapshot.summary.currency)
                } else {
                    Text("本月预算尚未设置").font(.subheadline).foregroundStyle(.secondary)
                }

                Divider()
                Text("即将续费").font(.subheadline.weight(.semibold))
                let upcoming = LifeDashboardRules.upcoming(snapshot.subscriptions,
                                                          today: LifeDashboardRules.dateKey(Date()))
                if upcoming.isEmpty {
                    Text("暂无待续费订阅").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(upcoming.prefix(3))) { subscription in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(subscription.name).font(.subheadline.weight(.medium))
                            Text("\(subscription.nextDueDate) · \(LifeDashboardRules.amount(subscription.amountMinor, currency: subscription.currency))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else if !model.isLoading && model.error == nil {
                Text("暂无生活数据").font(.subheadline).foregroundStyle(.secondary)
            }

            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { shortcuts }
                VStack(alignment: .leading, spacing: 12) { shortcuts }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .privacySensitive()
        .alert("暂未开放", isPresented: Binding(get: { unavailable != nil },
                                             set: { if !$0 { unavailable = nil } })) {
            Button("知道了", role: .cancel) { unavailable = nil }
        } message: {
            Text("\(unavailable ?? "此功能")将在后续阶段开放。")
        }
    }

    private func amountRow(_ title: String, _ amount: Int64, _ currency: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(LifeDashboardRules.amount(amount, currency: currency))
                .fontWeight(.medium).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private var shortcuts: some View {
        Group {
            Button(action: onAdd) { Label("记一笔", systemImage: "plus.circle") }.font(.subheadline)
            Button(action: onLedger) { Label("查看账本", systemImage: "list.bullet.rectangle") }.font(.subheadline)
            shortcut("订阅管理", symbol: "calendar.badge.clock")
        }
    }

    private func shortcut(_ title: String, symbol: String) -> some View {
        Button { unavailable = title } label: { Label(title, systemImage: symbol) }
            .font(.subheadline)
            .accessibilityHint("此功能尚未开放")
    }

    private func applyCurrency() {
        Task { await model.selectCurrency(currencyInput) }
    }
}
