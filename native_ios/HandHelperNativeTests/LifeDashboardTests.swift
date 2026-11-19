import Foundation
import XCTest
@testable import HandHelperNative

final class LifeDashboardTests: XCTestCase {
    func testBackendSummaryDecodesMinorUnitsAndUnconfiguredBudget() throws {
        let json = #"{"month":"2026-11","currency":"CNY","income_minor":10050,"expense_minor":99,"budget_minor":null,"remaining_minor":null}"#
        let summary = try JSONDecoder().decode(LifeSummary.self, from: Data(json.utf8))
        XCTAssertEqual(summary.incomeMinor, 10050)
        XCTAssertEqual(summary.expenseMinor, 99)
        XCTAssertNil(summary.budgetMinor)
        XCTAssertNil(summary.remainingMinor)
    }

    func testSubscriptionsFilterAndSortWithoutIncludingPausedOrPast() throws {
        let json = #"[{"id":1,"name":"later","amount_minor":100,"currency":"USD","next_due_date":"2026-12-01","status":"active"},{"id":2,"name":"paused","amount_minor":100,"currency":"CNY","next_due_date":"2026-11-20","status":"paused"},{"id":3,"name":"soon","amount_minor":100,"currency":"JPY","next_due_date":"2026-11-19","status":"active"},{"id":4,"name":"ended","amount_minor":100,"currency":"CNY","next_due_date":"2026-11-19","status":"ended"},{"id":5,"name":"past","amount_minor":100,"currency":"CNY","next_due_date":"2026-11-18","status":"active"}]"#
        let items = try JSONDecoder().decode([LifeSubscription].self, from: Data(json.utf8))
        XCTAssertEqual(LifeDashboardRules.upcoming(items, today: "2026-11-19").map(\.id), [3, 1])
    }

    func testMoneyDoesNotMixCurrenciesOrGuessUnknownPrecision() {
        XCTAssertTrue(LifeDashboardRules.validCurrency("CNY"))
        XCTAssertFalse(LifeDashboardRules.validCurrency("CNY&"))
        XCTAssertTrue(LifeDashboardRules.amount(105, currency: "CNY").hasPrefix("CNY "))
        XCTAssertTrue(LifeDashboardRules.amount(105, currency: "JPY").contains("105"))
        XCTAssertEqual(LifeDashboardRules.amount(105, currency: "XYZ"), "XYZ 105 最小单位")
    }

    func testTabLabelsPreserveOrderAndHomeIconFallback() {
        XCTAssertEqual(AppTab.allCases.map(\.title), ["生活", "课程表", "分析", "我的"])
        XCTAssertEqual(AppTab.today.symbol, "house")
    }

    @MainActor
    func testRepositoryUsesReadOnlyEndpointsAndAccountScopedCache() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let api = LifeAPIStub()
        let alice = await makeState(user: "alice", api: api)
        let revision = alice.authenticationRevision
        let owner = try alice.requireCurrentAccount(revision: revision)
        let repository = LifeRepository(state: alice, api: api, directory: folder)
        let snapshot = try await repository.refresh(owner: owner, revision: revision,
            month: "2026-11", currency: "CNY", isCurrent: { true })
        XCTAssertTrue(snapshot.hasTransactions)
        XCTAssertEqual(api.paths, ["GET /api/v1/life/summary?month=2026-11&currency=CNY",
            "GET /api/v1/life/transactions?month=2026-11&currency=CNY&limit=1",
            "GET /api/v1/life/subscriptions"])
        XCTAssertEqual(try repository.cached(owner: owner, revision: revision,
                                              month: "2026-11", currency: "CNY"), snapshot)
        let bob = await makeState(user: "bob", api: api)
        let bobOwner = try bob.requireCurrentAccount(revision: bob.authenticationRevision)
        XCTAssertNil(try LifeRepository(state: bob, api: api, directory: folder)
            .cached(owner: bobOwner, revision: bob.authenticationRevision, month: "2026-11", currency: "CNY"))
        XCTAssertThrowsError(try repository.cached(owner: bobOwner, revision: revision,
                                                    month: "2026-11", currency: "CNY"))
    }

    @MainActor
    private func makeState(user: String, api: LifeAPIStub) async -> AppState {
        let state = AppState(api: api, sessionStore: LifeSessionStub(cookie: "session=\(user)"),
                             authentication: LifeAuthStub(user: user),
                             preferences: UserDefaults(suiteName: UUID().uuidString)!)
        await state.restoreSession()
        return state
    }
}

private final class LifeAPIStub: APIClientProtocol {
    private(set) var paths: [String] = []
    func request<Value: Decodable>(_ method: String, path: String, body: Data?,
                                    preserveSessionOnPasswordError: Bool) async throws -> Value {
        paths.append("\(method) \(path)")
        let text: String
        if path.contains("/summary?") {
            text = #"{"month":"2026-11","currency":"CNY","income_minor":100,"expense_minor":0,"budget_minor":null,"remaining_minor":null}"#
        } else if path.contains("/transactions?") {
            text = #"[{"id":1}]"#
        } else if path == "/api/v1/life/subscriptions" {
            text = "[]"
        } else { throw APIError.invalidConfiguration }
        return try JSONDecoder().decode(Value.self, from: Data(text.utf8))
    }
}

private final class LifeSessionStub: SessionStore {
    var cookie: String?
    init(cookie: String) { self.cookie = cookie }
    func save(cookie: String) { self.cookie = cookie }
    @discardableResult func clear() -> Bool { cookie = nil; return true }
}

private final class LifeAuthStub: AuthenticationClientProtocol {
    let user: String
    init(user: String) { self.user = user }
    func login(username: String, password: String) async throws -> (cookie: String, identity: VerifiedIdentity) {
        ("session=\(username)", VerifiedIdentity(authenticated: true, username: username))
    }
    func verify(cookie: String) async throws -> VerifiedIdentity {
        VerifiedIdentity(authenticated: true, username: user)
    }
    func logout(cookie: String) async throws {}
}
