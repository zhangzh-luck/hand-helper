import SwiftUI

@MainActor
struct LedgerView: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: LedgerViewModel
    let didChange: () -> Void
    @State private var selectedDate = Date()
    @State private var currencyInput = "CNY"
    @State private var categoryFilter: Int?
    @State private var showingEditor = false
    @State private var showingBudget = false

    var body: some View {
        List {
            Section("查询") {
                DatePicker("月份", selection: $selectedDate, displayedComponents: .date)
                HStack {
                    TextField("币种代码", text: $currencyInput)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("查看") { applySelection() }
                }
                Text("选择日期所在月份；金额按币种分别统计。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let snapshot = model.snapshot {
                Section("\(model.month) · \(model.currency)") {
                    if model.cached { Text("当前显示本机缓存，只能查看") .foregroundStyle(.secondary) }
                    row("收入", snapshot.summary.incomeMinor)
                    row("支出", snapshot.summary.expenseMinor)
                    if let remaining = snapshot.summary.remainingMinor { row("剩余预算", remaining) }
                    else { Text("预算尚未设置").foregroundStyle(.secondary) }
                    Button("设置月度预算") { showingBudget = true }.disabled(!model.canWrite)
                }
                Section("交易记录") {
                    Picker("筛选", selection: $model.filter) {
                        Text("全部").tag("all"); Text("收入").tag("income"); Text("支出").tag("expense")
                    }.pickerStyle(.segmented)
                    Picker("分类", selection: $categoryFilter) {
                        Text("全部分类").tag(Int?.none)
                        ForEach((model.snapshot?.categories ?? []).filter { model.filter == "all" || $0.kind == model.filter }) { item in
                            Text(item.name).tag(Optional(item.id))
                        }
                    }
                    .onChange(of: model.filter) { _, _ in categoryFilter = nil }
                    if filtered.isEmpty { Text("暂无交易记录").foregroundStyle(.secondary) }
                    ForEach(Array(groupedDates), id: \.self) { date in
                        Text(date).font(.caption).foregroundStyle(.secondary)
                        ForEach(filtered.filter { $0.occurredOn == date }) { transaction in
                            NavigationLink {
                                TabBarHiddenNavigationDestination(state: state, tab: .today) {
                                    LedgerTransactionDetail(transaction: transaction, model: model, didChange: didChange)
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(categoryName(transaction))
                                        if !transaction.note.isEmpty { Text(transaction.note).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Text(LifeDashboardRules.amount(transaction.amountMinor, currency: transaction.currency))
                                        .foregroundStyle(transaction.kind == "income" ? Color.green : Color.primary)
                                }
                            }
                        }
                    }
                }
                Section {
                    NavigationLink("分类管理") {
                        TabBarHiddenNavigationDestination(state: state, tab: .today) {
                            LedgerCategoryView(model: model, didChange: didChange)
                        }
                    }
                }
            } else if model.loading {
                ProgressView("正在读取账本")
            } else {
                Section { Text("暂无可用账本数据").foregroundStyle(.secondary) }
            }
            if let error = model.error {
                Section { Text(error).foregroundStyle(.secondary); Button("重新读取") { Task { await model.refresh() } } }
            }
        }
        .navigationTitle("账本")
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingEditor = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("记一笔").disabled(!model.canWrite)
            }
        }
        .task { if model.snapshot == nil { await model.refresh() } }
        .refreshable { await model.refresh() }
        .sheet(isPresented: $showingEditor) { LedgerEditorSheet(model: model, transaction: nil, didChange: didChange) }
        .sheet(isPresented: $showingBudget) { LedgerBudgetSheet(model: model, didChange: didChange) }
        .privacySensitive()
    }

    private var groupedDates: [String] {
        Array(Set(filtered.map(\.occurredOn))).sorted(by: >)
    }
    private var filtered: [LedgerTransaction] {
        model.filtered.filter { categoryFilter == nil || $0.categoryID == categoryFilter }
    }
    private func categoryName(_ item: LedgerTransaction) -> String {
        model.snapshot?.categories.first(where: { $0.id == item.categoryID })?.name ?? (item.kind == "income" ? "收入" : "支出")
    }
    private func row(_ title: String, _ amount: Int64) -> some View {
        HStack { Text(title); Spacer(); Text(LifeDashboardRules.amount(amount, currency: model.currency)) }
            .accessibilityElement(children: .combine)
    }
    private func applySelection() {
        let month = String(LifeDashboardRules.dateKey(selectedDate).prefix(7))
        categoryFilter = nil
        Task { await model.change(month: month, currency: currencyInput) }
    }
}

@MainActor
struct LedgerEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: LedgerViewModel
    let transaction: LedgerTransaction?
    let didChange: () -> Void
    @State private var kind: String
    @State private var amount: String
    @State private var currency: String
    @State private var categoryID: Int?
    @State private var date: Date
    @State private var note: String
    @State private var validation: String?

    init(model: LedgerViewModel, transaction: LedgerTransaction?, didChange: @escaping () -> Void) {
        self.model = model; self.transaction = transaction; self.didChange = didChange
        _kind = State(initialValue: transaction?.kind ?? "expense")
        _currency = State(initialValue: transaction?.currency ?? model.currency)
        _amount = State(initialValue: transaction.map { LedgerAmount.input($0.amountMinor, currency: $0.currency) } ?? "")
        _categoryID = State(initialValue: transaction?.categoryID)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        _date = State(initialValue: transaction.flatMap { formatter.date(from: $0.occurredOn) } ?? Date())
        _note = State(initialValue: transaction?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类型", selection: $kind) { Text("支出").tag("expense"); Text("收入").tag("income") }
                        .pickerStyle(.segmented)
                        .onChange(of: kind) { _, _ in categoryID = nil }
                    TextField("金额", text: $amount).keyboardType(.decimalPad)
                    TextField("币种，例如 CNY", text: $currency).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Picker("分类", selection: $categoryID) {
                        Text("未分类").tag(Int?.none)
                        ForEach((model.snapshot?.categories ?? []).filter { $0.kind == kind }) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    TextField("备注（选填）", text: $note, axis: .vertical)
                }
                if let validation { Text(validation).foregroundStyle(.red) }
                if let error = model.error { Text(error).foregroundStyle(.secondary) }
                if model.uncertain {
                    Text("请关闭此窗口，在账本中选择本笔交易的月份和币种，刷新并核对后再决定是否重试。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(transaction == nil ? "记一笔" : "编辑交易")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(model.saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!model.canWrite)
                }
            }
            .task { if model.snapshot == nil { await model.refresh() } }
        }
        .interactiveDismissDisabled(model.saving)
        .privacySensitive()
    }

    private func save() {
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let minor = LedgerAmount.parse(amount, currency: code), note.count <= 1000 else {
            validation = "请输入支持币种的有效金额，备注最多 1000 字。"; return
        }
        let input = LedgerTransactionInput(kind: kind, amountMinor: minor, currency: code,
            categoryID: categoryID, occurredOn: LifeDashboardRules.dateKey(date), note: note)
        Task {
            if await model.saveTransaction(input, id: transaction?.id) {
                dismiss(); didChange(); await model.refresh()
            }
        }
    }
}

@MainActor
private struct LedgerTransactionDetail: View {
    @Environment(\.dismiss) private var dismiss
    let transaction: LedgerTransaction
    @ObservedObject var model: LedgerViewModel
    let didChange: () -> Void
    @State private var editing = false
    @State private var deleting = false
    var body: some View {
        List {
            LabeledContent("金额", value: LifeDashboardRules.amount(transaction.amountMinor, currency: transaction.currency))
            LabeledContent("类型", value: transaction.kind == "income" ? "收入" : "支出")
            LabeledContent("日期", value: transaction.occurredOn)
            LabeledContent("分类", value: model.snapshot?.categories.first(where: { $0.id == transaction.categoryID })?.name ?? "未分类")
            if !transaction.note.isEmpty { LabeledContent("备注", value: transaction.note) }
            if let error = model.error { Text(error).foregroundStyle(.secondary) }
            if model.uncertain { Button("刷新账本并核对") { Task { await model.refresh() } } }
            Button("编辑") { editing = true }.disabled(!model.canWrite)
            Button("删除交易", role: .destructive) { deleting = true }.disabled(!model.canWrite)
        }
        .navigationTitle("交易详情")
        .sheet(isPresented: $editing) {
            LedgerEditorSheet(model: model, transaction: transaction) { didChange(); dismiss() }
        }
        .confirmationDialog("确定删除这笔交易？", isPresented: $deleting) {
            Button("删除", role: .destructive) {
                Task { if await model.deleteTransaction(transaction.id) { didChange(); await model.refresh(); dismiss() } }
            }
        }
    }
}

@MainActor
private struct LedgerBudgetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: LedgerViewModel
    let didChange: () -> Void
    @State private var amount = ""
    @State private var validation: String?
    var body: some View {
        NavigationStack {
            Form {
                Text("\(model.month) · \(model.currency)")
                TextField("预算金额", text: $amount).keyboardType(.decimalPad)
                if let validation { Text(validation).foregroundStyle(.red) }
                if let error = model.error { Text(error).foregroundStyle(.secondary) }
                if model.uncertain { Button("刷新并核对") { Task { await model.refresh() } } }
            }
            .navigationTitle("月度预算")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(model.saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!model.canWrite)
                }
            }
        }.interactiveDismissDisabled(model.saving)
    }
    private func save() {
        guard let value = LedgerAmount.parse(amount, currency: model.currency, allowZero: true) else {
            validation = "请输入有效预算金额"; return
        }
        Task { if await model.saveBudget(value) { dismiss(); didChange(); await model.refresh() } }
    }
}

@MainActor
private struct LedgerCategoryView: View {
    @ObservedObject var model: LedgerViewModel
    let didChange: () -> Void
    @State private var name = ""
    @State private var kind = "expense"
    @State private var editing: LedgerCategory?
    @State private var deleteItem: LedgerCategory?
    var body: some View {
        List {
            Section(editing == nil ? "新增分类" : "编辑分类") {
                TextField("分类名称", text: $name)
                Picker("类型", selection: $kind) { Text("支出").tag("expense"); Text("收入").tag("income") }
                    .disabled(editing != nil)
                Button(editing == nil ? "新增" : "保存") { save() }.disabled(!model.canWrite || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if editing != nil { Button("取消编辑") { reset() } }
            }
            Section("已有分类") {
                ForEach(model.snapshot?.categories ?? []) { item in
                    HStack {
                        Button("\(item.name) · \(item.kind == "income" ? "收入" : "支出")") {
                            editing = item; name = item.name; kind = item.kind
                        }.disabled(!model.canWrite)
                        Spacer()
                        Button(role: .destructive) { deleteItem = item } label: { Image(systemName: "trash") }
                            .accessibilityLabel("删除分类 \(item.name)").disabled(!model.canWrite)
                    }
                }
            }
            if let error = model.error { Section { Text(error).foregroundStyle(.secondary) } }
            if model.uncertain { Button("刷新并核对") { Task { await model.refresh() } } }
        }
        .navigationTitle("分类管理")
        .confirmationDialog("确定删除分类？", isPresented: Binding(get: { deleteItem != nil }, set: { if !$0 { deleteItem = nil } }), presenting: deleteItem) { item in
            Button("删除", role: .destructive) {
                Task { if await model.deleteCategory(item.id) { reset(); didChange(); await model.refresh() }; deleteItem = nil }
            }
        } message: { _ in Text("已被交易使用的分类不能删除。") }
    }
    private func reset() { editing = nil; name = ""; kind = "expense" }
    private func save() {
        let input = LedgerCategoryInput(name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind)
        Task { if await model.saveCategory(input, id: editing?.id) { reset(); didChange(); await model.refresh() } }
    }
}
