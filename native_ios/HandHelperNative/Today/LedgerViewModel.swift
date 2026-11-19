import Combine
import Foundation

@MainActor
final class LedgerViewModel: ObservableObject {
    @Published private(set) var snapshot: LedgerSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var cached = false
    @Published private(set) var error: String?
    @Published private(set) var uncertain = false
    @Published var filter = "all"
    @Published private(set) var month = String(LifeDashboardRules.dateKey(Date()).prefix(7))
    @Published private(set) var currency = "CNY"
    private let state: AppState
    private let repository: LedgerRepository
    private var generation = 0
    private var writeGeneration = 0

    init(state: AppState, repository: LedgerRepository? = nil) {
        self.state = state; self.repository = repository ?? LedgerRepository(state: state)
    }

    var canWrite: Bool { state.canAccessPrivateData && !cached && !loading && !saving && !uncertain && snapshot != nil }
    var filtered: [LedgerTransaction] {
        (snapshot?.transactions ?? []).filter { filter == "all" || $0.kind == filter }
    }

    func clear() {
        generation += 1; writeGeneration += 1
        snapshot = nil; loading = false; saving = false; cached = false; error = nil; uncertain = false
    }

    func change(month: String, currency: String) async {
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard LifeDashboardRules.validCurrency(code), LedgerAmount.precision(code) != nil,
              month.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil else {
            error = "请输入有效月份及支持的币种代码。"; return
        }
        guard !saving else { return }
        self.month = month; self.currency = code; filter = "all"; clear()
        await refresh()
    }

    func refresh() async {
        let revision = state.authenticationRevision
        guard state.canAccessPrivateData, let owner = try? state.requireCurrentAccount(revision: revision) else { clear(); return }
        generation += 1
        let ticket = generation, selectedMonth = month, selectedCurrency = currency
        let current = { [weak self] in
            guard let self else { return false }
            return self.generation == ticket && self.state.authenticationRevision == revision &&
                self.month == selectedMonth && self.currency == selectedCurrency && self.state.canAccessPrivateData &&
                (try? self.state.requireCurrentAccount(revision: revision)) == owner
        }
        loading = true; error = nil
        if snapshot == nil {
            snapshot = try? repository.cached(owner: owner, revision: revision, month: selectedMonth, currency: selectedCurrency)
            cached = snapshot != nil
        }
        do {
            let loaded = try await repository.load(owner: owner, revision: revision, month: selectedMonth,
                                                   currency: selectedCurrency, isCurrent: current)
            guard current() else { return }
            snapshot = loaded; cached = false; loading = false; uncertain = false
        } catch {
            guard current() else { return }
            loading = false; cached = snapshot != nil
            self.error = "账本读取失败，请检查网络后重试。"
        }
    }

    private func beginWrite() -> (String, Int, Int)? {
        let revision = state.authenticationRevision
        guard canWrite, let owner = try? state.requireCurrentAccount(revision: revision) else { return nil }
        writeGeneration += 1; saving = true; error = nil
        return (owner, revision, writeGeneration)
    }

    private func finishWrite(_ error: Error?, ticket: (String, Int, Int)) -> Bool {
        guard ticket.2 == writeGeneration, ticket.1 == state.authenticationRevision,
              (try? state.requireCurrentAccount(revision: ticket.1)) == ticket.0 else { return false }
        saving = false
        guard let error else { return true }
        if let apiError = error as? APIError {
            switch apiError {
            case .timeout, .connection, .invalidResponse, .invalidData:
                uncertain = true
                self.error = "操作结果不确定，请先刷新账本核对，勿重复提交。"
            case .server(let status, _) where status >= 500:
                uncertain = true
                self.error = "服务器未确认结果，请先刷新账本核对，勿重复提交。"
            case .server(let status, let message) where status == 409:
                self.error = message
            default: self.error = apiError.message
            }
        } else { self.error = "操作失败，请检查输入后重试。" }
        return false
    }

    func saveTransaction(_ input: LedgerTransactionInput, id: Int?) async -> Bool {
        guard let ticket = beginWrite() else { return false }
        do {
            let _: LedgerTransaction = try await repository.write(id == nil ? "POST" : "PUT",
                path: "/api/v1/life/transactions" + (id.map { "/\($0)" } ?? ""), body: input,
                owner: ticket.0, revision: ticket.1)
            return finishWrite(nil, ticket: ticket)
        } catch { return finishWrite(error, ticket: ticket) }
    }

    func deleteTransaction(_ id: Int) async -> Bool {
        guard let ticket = beginWrite() else { return false }
        do {
            let _: LedgerDeleted = try await repository.write("DELETE", path: "/api/v1/life/transactions/\(id)",
                body: Optional<LedgerTransactionInput>.none, owner: ticket.0, revision: ticket.1)
            return finishWrite(nil, ticket: ticket)
        } catch { return finishWrite(error, ticket: ticket) }
    }

    func saveCategory(_ input: LedgerCategoryInput, id: Int?) async -> Bool {
        guard let ticket = beginWrite() else { return false }
        do {
            let _: LedgerCategory = try await repository.write(id == nil ? "POST" : "PUT",
                path: "/api/v1/life/categories" + (id.map { "/\($0)" } ?? ""), body: input,
                owner: ticket.0, revision: ticket.1)
            return finishWrite(nil, ticket: ticket)
        } catch { return finishWrite(error, ticket: ticket) }
    }

    func deleteCategory(_ id: Int) async -> Bool {
        guard let ticket = beginWrite() else { return false }
        do {
            let _: LedgerDeleted = try await repository.write("DELETE", path: "/api/v1/life/categories/\(id)",
                body: Optional<LedgerCategoryInput>.none, owner: ticket.0, revision: ticket.1)
            return finishWrite(nil, ticket: ticket)
        } catch { return finishWrite(error, ticket: ticket) }
    }

    func saveBudget(_ amount: Int64) async -> Bool {
        guard let ticket = beginWrite() else { return false }
        do {
            let _: LedgerBudget = try await repository.write("PUT", path: "/api/v1/life/budgets/\(month)",
                body: LedgerBudgetInput(amountMinor: amount, currency: currency), owner: ticket.0, revision: ticket.1)
            return finishWrite(nil, ticket: ticket)
        } catch { return finishWrite(error, ticket: ticket) }
    }
}
