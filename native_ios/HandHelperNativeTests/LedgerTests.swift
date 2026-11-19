import Foundation
import XCTest
@testable import HandHelperNative

final class LedgerTests: XCTestCase {
    func testExactMinorUnitsAndLimits() {
        XCTAssertEqual(LedgerAmount.parse("12.34", currency: "CNY"), 1234)
        XCTAssertEqual(LedgerAmount.parse("1.001", currency: "KWD"), 1001)
        XCTAssertEqual(LedgerAmount.parse("123", currency: "JPY"), 123)
        XCTAssertNil(LedgerAmount.parse("1.1", currency: "JPY"))
        XCTAssertNil(LedgerAmount.parse("1.001", currency: "USD"))
        XCTAssertNil(LedgerAmount.parse("-1", currency: "CNY"))
        XCTAssertNil(LedgerAmount.parse("1e3", currency: "CNY"))
        XCTAssertNil(LedgerAmount.parse("999999999999999999999", currency: "CNY"))
        XCTAssertNil(LedgerAmount.parse("0", currency: "USD"))
        XCTAssertEqual(LedgerAmount.parse("0", currency: "USD", allowZero: true), 0)
        XCTAssertNil(LedgerAmount.parse("1.00", currency: "XYZ"))
        XCTAssertEqual(LedgerAmount.input(1234, currency: "CNY"), "12.34")
    }

    func testBackendTransactionDecodesNullableCategoryAndIntegerAmount() throws {
        let json = #"{"id":7,"kind":"expense","amount_minor":1234,"currency":"CNY","category_id":null,"occurred_on":"2024-02-29","note":""}"#
        let value = try JSONDecoder().decode(LedgerTransaction.self, from: Data(json.utf8))
        XCTAssertEqual(value.amountMinor, 1234)
        XCTAssertEqual(value.occurredOn, "2024-02-29")
        XCTAssertNil(value.categoryID)
        let body = LedgerTransactionInput(kind: "expense", amountMinor: 1234, currency: "CNY",
                                          categoryID: nil, occurredOn: "2024-02-29", note: "")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        XCTAssertEqual(encoded?["amount_minor"] as? Int64, 1234)
        XCTAssertEqual(encoded?["occurred_on"] as? String, "2024-02-29")
    }

    func testSummaryUsesExactSignedBudgetAndMonth() throws {
        let json = #"{"month":"2024-02","currency":"CNY","income_minor":0,"expense_minor":123,"budget_minor":100,"remaining_minor":-23}"#
        let value = try JSONDecoder().decode(LifeSummary.self, from: Data(json.utf8))
        XCTAssertEqual(value.month, "2024-02")
        XCTAssertEqual(value.remainingMinor, -23)
    }

    @MainActor
    func testWriteFailureAndSubscriptionConflictLeaveStateUsable() async {
        let api = LedgerAPIStub()
        let state = await makeState(api: api)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = LedgerViewModel(state: state, repository: LedgerRepository(state: state, api: api, directory: folder))
        await model.refresh()
        XCTAssertTrue(model.canWrite)
        api.writeError = .server(status: 409, message: "订阅付款关联的交易不可修改")
        let saved = await model.saveTransaction(input(), id: 8)
        XCTAssertFalse(saved)
        XCTAssertFalse(model.saving)
        XCTAssertTrue(model.error?.contains("订阅付款") == true)
        XCTAssertTrue(model.canWrite)
        api.writeError = .timeout
        let failed = await model.saveTransaction(input(), id: nil)
        XCTAssertFalse(failed)
        XCTAssertTrue(model.uncertain)
        XCTAssertFalse(model.canWrite)
    }

    @MainActor
    func testCreateUpdateDeleteAndFilter() async {
        let api = LedgerAPIStub()
        api.transactions = #"[{"id":5,"kind":"income","amount_minor":100,"currency":"CNY","category_id":null,"occurred_on":"2024-02-29","note":""},{"id":6,"kind":"expense","amount_minor":200,"currency":"CNY","category_id":null,"occurred_on":"2024-02-29","note":""}]"#
        let state = await makeState(api: api)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = LedgerViewModel(state: state, repository: LedgerRepository(state: state, api: api, directory: folder))
        await model.refresh()
        model.filter = "income"
        XCTAssertEqual(model.filtered.map(\.id), [5])
        let created = await model.saveTransaction(input(), id: nil)
        XCTAssertTrue(created)
        let updated = await model.saveTransaction(input(), id: 1)
        XCTAssertTrue(updated)
        let deleted = await model.deleteTransaction(1)
        XCTAssertTrue(deleted)
        let budget = await model.saveBudget(1_000)
        XCTAssertTrue(budget)
    }

    @MainActor
    func testCacheIsIdentityScopedAndInvalidatedSessionCannotRead() async throws {
        let api = LedgerAPIStub()
        let state = await makeState(api: api)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = LedgerRepository(state: state, api: api, directory: folder)
        let revision = state.authenticationRevision
        let owner = try state.requireCurrentAccount(revision: revision)
        let month = String(LifeDashboardRules.dateKey(Date()).prefix(7))
        let snapshot = try await repository.load(owner: owner, revision: revision, month: month,
                                                  currency: "CNY", isCurrent: { true })
        XCTAssertEqual(try repository.cached(owner: owner, revision: revision, month: month, currency: "CNY"), snapshot)
        XCTAssertThrowsError(try repository.cached(owner: "user:someone-else", revision: revision,
                                                    month: month, currency: "CNY"))
        await state.logout()
        XCTAssertThrowsError(try repository.cached(owner: owner, revision: revision, month: month, currency: "CNY"))
    }

    @MainActor
    func testRapidRepeatAndIdentityCleanupRejectLateResponse() async {
        let api = LedgerAPIStub()
        let state = await makeState(api: api)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = LedgerViewModel(state: state, repository: LedgerRepository(state: state, api: api, directory: folder))
        await model.refresh()
        api.waitForWrite = true
        let task = Task { await model.saveTransaction(input(), id: nil) }
        await fulfillment(of: [api.started], timeout: 3)
        let duplicate = await model.saveTransaction(input(), id: nil)
        XCTAssertFalse(duplicate)
        XCTAssertEqual(api.writeCount, 1)
        await state.logout()
        model.clear()
        api.finishWrite()
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.saving)
    }

    @MainActor
    private func makeState(api: LedgerAPIStub) async -> AppState {
        let state = AppState(api: api, sessionStore: LedgerSessionStub(), authentication: LedgerAuthStub(),
                             preferences: UserDefaults(suiteName: UUID().uuidString)!)
        await state.restoreSession()
        return state
    }

    private func input() -> LedgerTransactionInput {
        LedgerTransactionInput(kind: "expense", amountMinor: 100, currency: "CNY",
                               categoryID: nil, occurredOn: "2024-02-29", note: "")
    }
}

private final class LedgerAPIStub: APIClientProtocol {
    var writeError: APIError?
    var waitForWrite = false
    var writeCount = 0
    var transactions = "[]"
    let started = XCTestExpectation(description: "ledger write started")
    private var continuation: CheckedContinuation<Void, Never>?

    func request<Value: Decodable>(_ method: String, path: String, body: Data?,
                                    preserveSessionOnPasswordError: Bool) async throws -> Value {
        if method != "GET" {
            writeCount += 1
            if waitForWrite {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    started.fulfill()
                }
            }
            if let writeError { throw writeError }
            if method == "DELETE" {
                return try JSONDecoder().decode(Value.self, from: Data(#"{"deleted":true}"#.utf8))
            }
            if path.contains("/budgets/") {
                return try JSONDecoder().decode(Value.self, from: Data(#"{"amount_minor":1000}"#.utf8))
            }
            let value = #"{"id":1,"kind":"expense","amount_minor":100,"currency":"CNY","category_id":null,"occurred_on":"2024-02-29","note":""}"#
            return try JSONDecoder().decode(Value.self, from: Data(value.utf8))
        }
        let response: String
        if path.contains("/summary?") {
            let month = String(LifeDashboardRules.dateKey(Date()).prefix(7))
            response = "{\"month\":\"\(month)\",\"currency\":\"CNY\",\"income_minor\":0,\"expense_minor\":0,\"budget_minor\":null,\"remaining_minor\":null}"
        } else if path.contains("/transactions?") { response = transactions }
        else { response = "[]" }
        return try JSONDecoder().decode(Value.self, from: Data(response.utf8))
    }

    func finishWrite() { continuation?.resume(); continuation = nil }
}

private final class LedgerSessionStub: SessionStore {
    var cookie: String? = "session=test"
    func save(cookie: String) { self.cookie = cookie }
    @discardableResult func clear() -> Bool { cookie = nil; return true }
}

private final class LedgerAuthStub: AuthenticationClientProtocol {
    func login(username: String, password: String) async throws -> (cookie: String, identity: VerifiedIdentity) {
        ("session=test", VerifiedIdentity(authenticated: true, username: "test"))
    }
    func verify(cookie: String) async throws -> VerifiedIdentity { VerifiedIdentity(authenticated: true, username: "test") }
    func logout(cookie: String) async throws {}
}
