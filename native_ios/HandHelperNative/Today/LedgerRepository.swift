import CryptoKit
import Darwin
import Foundation

@MainActor
final class LedgerRepository {
    private struct Cache: Codable { let owner: String; let baseURL: String; let snapshot: LedgerSnapshot }
    private let state: AppState
    private let api: any APIClientProtocol
    private let baseURL: URL
    private let directory: URL

    init(state: AppState, api: (any APIClientProtocol)? = nil, directory: URL? = nil,
         baseURL: URL = APIConfiguration.development.baseURL) {
        self.state = state; self.api = api ?? state.api; self.baseURL = baseURL
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private func check(_ owner: String, _ revision: Int) throws {
        guard try state.requireCurrentAccount(revision: revision) == owner else {
            throw APIError.unauthorized(message: "登录账号已变化")
        }
    }

    private func file(owner: String, month: String, currency: String) -> URL {
        let text = "\(baseURL.absoluteString)|\(owner)|\(month)|\(currency)"
        let key = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("life_ledger_\(key).json")
    }

    func cached(owner: String, revision: Int, month: String, currency: String) throws -> LedgerSnapshot? {
        try check(owner, revision)
        let url = file(owner: owner, month: month, currency: currency)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: url))
        guard value.owner == owner, value.baseURL == baseURL.absoluteString,
              value.snapshot.summary.month == month, value.snapshot.summary.currency == currency else { return nil }
        try check(owner, revision)
        return value.snapshot
    }

    func load(owner: String, revision: Int, month: String, currency: String,
              isCurrent: () -> Bool) async throws -> LedgerSnapshot {
        guard isCurrent(), LifeDashboardRules.validCurrency(currency),
              month.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil else {
            throw APIError.invalidConfiguration
        }
        func validate() throws {
            guard isCurrent() else { throw CancellationError() }
            try check(owner, revision)
        }
        try validate()
        let query = "month=\(month)&currency=\(currency)"
        let summary: LifeSummary = try await api.request("GET", path: "/api/v1/life/summary?\(query)",
                                                          body: nil, preserveSessionOnPasswordError: false)
        try validate()
        guard summary.month == month, summary.currency == currency else { throw APIError.invalidResponse }
        let categories: [LedgerCategory] = try await api.request("GET", path: "/api/v1/life/categories",
                                                                  body: nil, preserveSessionOnPasswordError: false)
        try validate()
        var records: [LedgerTransaction] = []
        var offset = 0
        repeat {
            let page: [LedgerTransaction] = try await api.request("GET",
                path: "/api/v1/life/transactions?\(query)&limit=200&offset=\(offset)",
                body: nil, preserveSessionOnPasswordError: false)
            try validate()
            records.append(contentsOf: page)
            offset += page.count
            if page.count < 200 { break }
            guard offset < 20_000 else { throw APIError.invalidResponse }
        } while true
        let snapshot = LedgerSnapshot(summary: summary, transactions: records, categories: categories, savedAt: Date())
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = file(owner: owner, month: month, currency: currency)
            let temporary = directory.appendingPathComponent(".ledger-tmp-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let data = try JSONEncoder().encode(Cache(owner: owner, baseURL: baseURL.absoluteString, snapshot: snapshot))
            try data.write(to: temporary, options: .completeFileProtectionUntilFirstUserAuthentication)
            try validate()
            let result = temporary.path.withCString { source in target.path.withCString { Darwin.rename(source, $0) } }
            guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var targetURL = target; try? targetURL.setResourceValues(values)
        } catch { try validate() }
        return snapshot
    }

    func write<Value: Decodable, Body: Encodable>(_ method: String, path: String, body: Body?,
                                                    owner: String, revision: Int) async throws -> Value {
        try check(owner, revision)
        let encoded = try body.map { try JSONEncoder().encode($0) }
        let result: Value = try await api.request(method, path: path, body: encoded,
                                                  preserveSessionOnPasswordError: false)
        try check(owner, revision)
        return result
    }
}
