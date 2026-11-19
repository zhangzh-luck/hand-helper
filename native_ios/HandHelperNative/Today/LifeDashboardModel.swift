import CryptoKit
import Combine
import Darwin
import Foundation

struct LifeSummary: Codable, Equatable {
    let month: String
    let currency: String
    let incomeMinor: Int64
    let expenseMinor: Int64
    let budgetMinor: Int64?
    let remainingMinor: Int64?

    enum CodingKeys: String, CodingKey {
        case month, currency
        case incomeMinor = "income_minor", expenseMinor = "expense_minor"
        case budgetMinor = "budget_minor", remainingMinor = "remaining_minor"
    }
}

struct LifeTransactionReference: Decodable { let id: Int }

struct LifeSubscription: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let amountMinor: Int64
    let currency: String
    let nextDueDate: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, name, currency, status
        case amountMinor = "amount_minor", nextDueDate = "next_due_date"
    }
}

struct LifeSnapshot: Codable, Equatable {
    let summary: LifeSummary
    let hasTransactions: Bool
    let subscriptions: [LifeSubscription]
    let savedAt: Date
}

enum LifeDashboardRules {
    static func validCurrency(_ value: String) -> Bool {
        value.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil
    }

    static func dateKey(_ date: Date, calendar: Calendar? = nil) -> String {
        var calendar = calendar ?? Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0,
                      components.month ?? 0, components.day ?? 0)
    }

    static func upcoming(_ items: [LifeSubscription], today: String) -> [LifeSubscription] {
        items.filter { $0.status == "active" && $0.nextDueDate >= today }
            .sorted { ($0.nextDueDate, $0.id) < ($1.nextDueDate, $1.id) }
    }

    static func amount(_ amount: Int64, currency: String) -> String {
        // Never guess an unrecognised currency's smallest-unit exponent.
        let digits: Int
        switch currency {
        case "CNY", "USD", "EUR", "GBP", "HKD", "CAD", "AUD": digits = 2
        case "JPY", "KRW": digits = 0
        case "KWD", "BHD": digits = 3
        default: return "\(currency) \(amount) 最小单位"
        }
        var divisor = Decimal(1)
        for _ in 0..<digits { divisor *= 10 }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        let value = NSDecimalNumber(decimal: Decimal(amount) / divisor)
        return "\(currency) \(formatter.string(from: value) ?? value.stringValue)"
    }
}

@MainActor
final class LifeRepository {
    private struct Cache: Codable {
        let owner: String
        let baseURL: String
        let snapshot: LifeSnapshot
    }

    private let state: AppState
    private let api: any APIClientProtocol
    private let directory: URL
    private let baseURL: URL

    init(state: AppState, api: (any APIClientProtocol)? = nil,
         directory: URL? = nil, baseURL: URL = APIConfiguration.development.baseURL) {
        self.state = state
        self.api = api ?? state.api
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                                 in: .userDomainMask)[0]
        self.baseURL = baseURL
    }

    private func file(owner: String, month: String, currency: String) -> URL {
        let key = "\(baseURL.absoluteString)|\(owner)|\(month)|\(currency)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("life_dashboard_\(hash).json")
    }

    private func requireOwner(_ owner: String, revision: Int) throws {
        guard try state.requireCurrentAccount(revision: revision) == owner else {
            throw APIError.unauthorized(message: "登录账号已变化")
        }
    }

    func cached(owner: String, revision: Int, month: String, currency: String) throws -> LifeSnapshot? {
        try requireOwner(owner, revision: revision)
        let url = file(owner: owner, month: month, currency: currency)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: url))
        guard cache.owner == owner, cache.baseURL == baseURL.absoluteString,
              cache.snapshot.summary.month == month, cache.snapshot.summary.currency == currency else { return nil }
        try requireOwner(owner, revision: revision)
        return cache.snapshot
    }

    func refresh(owner: String, revision: Int, month: String, currency: String,
                 isCurrent: () -> Bool) async throws -> LifeSnapshot {
        guard LifeDashboardRules.validCurrency(currency), isCurrent() else { throw APIError.invalidConfiguration }
        try requireOwner(owner, revision: revision)
        let query = "month=\(month)&currency=\(currency)"
        let summary: LifeSummary = try await api.request("GET", path: "/api/v1/life/summary?\(query)",
            body: nil, preserveSessionOnPasswordError: false)
        guard isCurrent(), summary.month == month, summary.currency == currency else { throw CancellationError() }
        try requireOwner(owner, revision: revision)
        let transactions: [LifeTransactionReference] = try await api.request("GET",
            path: "/api/v1/life/transactions?\(query)&limit=1", body: nil, preserveSessionOnPasswordError: false)
        guard isCurrent() else { throw CancellationError() }
        try requireOwner(owner, revision: revision)
        let subscriptions: [LifeSubscription] = try await api.request("GET", path: "/api/v1/life/subscriptions",
            body: nil, preserveSessionOnPasswordError: false)
        guard isCurrent() else { throw CancellationError() }
        try requireOwner(owner, revision: revision)
        let snapshot = LifeSnapshot(summary: summary, hasTransactions: !transactions.isEmpty,
                                    subscriptions: subscriptions, savedAt: Date())
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = file(owner: owner, month: month, currency: currency)
            let temporary = directory.appendingPathComponent(".life-tmp-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let data = try JSONEncoder().encode(Cache(owner: owner, baseURL: baseURL.absoluteString, snapshot: snapshot))
            try data.write(to: temporary, options: .completeFileProtectionUntilFirstUserAuthentication)
            guard isCurrent() else { throw CancellationError() }
            try requireOwner(owner, revision: revision)
            let status = temporary.path.withCString { source in target.path.withCString { destination in
                Darwin.rename(source, destination)
            } }
            guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = true
            var mutableTarget = target
            try? mutableTarget.setResourceValues(resource)
        } catch {
            // Cache failure must not hide a valid server response, but identity
            // changes must still reject the response itself.
            guard isCurrent() else { throw CancellationError() }
            try requireOwner(owner, revision: revision)
        }
        return snapshot
    }
}

@MainActor
final class LifeDashboardModel: ObservableObject {
    @Published private(set) var snapshot: LifeSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var isCached = false
    @Published private(set) var currency = "CNY"
    private let state: AppState
    private let repository: LifeRepository
    private var generation = 0
    private var loadedScope: String?

    init(state: AppState, repository: LifeRepository? = nil) {
        self.state = state
        self.repository = repository ?? LifeRepository(state: state)
    }

    func clear() {
        generation += 1
        snapshot = nil; error = nil; isLoading = false; isCached = false; loadedScope = nil
    }

    func selectCurrency(_ value: String) async {
        let code = value.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard LifeDashboardRules.validCurrency(code) else { error = "请输入三位大写币种代码"; return }
        guard code != currency else { return }
        currency = code
        clear()
        await load(force: false)
    }

    func load(force: Bool = false) async {
        let revision = state.authenticationRevision
        guard state.canAccessPrivateData, let owner = try? state.requireCurrentAccount(revision: revision) else {
            clear(); return
        }
        let month = String(LifeDashboardRules.dateKey(Date()).prefix(7))
        let scope = "\(owner)|\(month)|\(currency)|\(revision)"
        guard force || (!isLoading && loadedScope != scope) else { return }
        generation += 1
        let ticket = generation
        let selected = currency
        if snapshot?.summary.month != month || snapshot?.summary.currency != selected {
            snapshot = nil
            isCached = false
        }
        let current = { [weak self] in
            guard let self else { return false }
            return self.generation == ticket && self.currency == selected &&
                self.state.authenticationRevision == revision && self.state.canAccessPrivateData &&
                (try? self.state.requireCurrentAccount(revision: revision)) == owner
        }
        isLoading = true; error = nil
        if !force {
            snapshot = try? repository.cached(owner: owner, revision: revision, month: month, currency: selected)
            isCached = snapshot != nil
        }
        do {
            let value = try await repository.refresh(owner: owner, revision: revision, month: month,
                                                     currency: selected, isCurrent: current)
            guard current() else { return }
            snapshot = value; loadedScope = scope; isCached = false; isLoading = false
        } catch {
            guard current() else { return }
            isLoading = false
            loadedScope = scope
            self.error = "生活数据读取失败，请检查网络或稍后重试。"
            isCached = snapshot != nil
        }
    }
}
