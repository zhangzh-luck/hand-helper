import Foundation
import XCTest
@testable import HandHelperNative

final class AnalysisDataTests: XCTestCase {
    private let terms = #"[{"id":8,"source_term_id":"2025-2026-2","display_name":"2025-2026 第二学期","start_date":null,"is_current":true}]"#
    private let grades = #"[{"id":4,"term_id":8,"course_code":"C001","course_name":"机器学习","course_type":null,"credits":2.5,"score":"良好","final_exam_score":null,"usual_score":null,"grade_point":3.2,"weighted_grade_point":8,"exam_type":null,"makeup_flag":false,"retake_flag":true}]"#
    private let summary = #"{"total_courses":1,"total_credits":2.5,"earned_credits":2.5,"failed_courses":0,"average_score":71.25,"gpa":3.17,"gpa_note":"服务端估算"}"#

    func testPersistedGradeAndSummaryDecodeWithoutClientRecalculation() throws {
        let grade = try XCTUnwrap(JSONDecoder().decode([GradeRecord].self, from: Data(grades.utf8)).first)
        XCTAssertEqual(grade.courseName, "机器学习")
        XCTAssertEqual(grade.score, "良好")
        XCTAssertNil(grade.finalExamScore)
        XCTAssertTrue(grade.retakeFlag)
        let value = try JSONDecoder().decode(GradeSummary.self, from: Data(summary.utf8))
        XCTAssertEqual(value.averageScore, 71.25)
        XCTAssertEqual(value.gpa, 3.17)
        XCTAssertEqual(value.gpaNote, "服务端估算")
    }

    @MainActor
    func testRefreshUsesActualPathsAndCacheIsAccountScoped() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let api = AnalysisAPIStub(responses: [
            "/api/v1/terms": terms,
            "/api/v1/grades?term_id=8": grades,
            "/api/v1/grades/summary?term_id=8": summary,
            "/api/v1/grades/ai-analyses?term_id=8": "[]"
        ])
        let alice = await makeState(user: "alice", api: api)
        let aliceOwner = try alice.requireCurrentAccount(revision: alice.authenticationRevision)
        let repo = AnalysisRepository(state: alice, api: api, directory: folder)
        let snapshot = try await repo.refresh(owner: aliceOwner, revision: alice.authenticationRevision)
        XCTAssertEqual(snapshot.byTerm[8]?.grades.first?.courseName, "机器学习")
        XCTAssertEqual(api.paths, ["/api/v1/terms", "/api/v1/grades?term_id=8",
                                   "/api/v1/grades/summary?term_id=8",
                                   "/api/v1/grades/ai-analyses?term_id=8"])
        XCTAssertEqual(try repo.cached(owner: aliceOwner, revision: alice.authenticationRevision), snapshot)

        let bob = await makeState(user: "bob", api: api)
        let bobOwner = try bob.requireCurrentAccount(revision: bob.authenticationRevision)
        XCTAssertNil(try AnalysisRepository(state: bob, api: api, directory: folder)
            .cached(owner: bobOwner, revision: bob.authenticationRevision))
        let rotatedAlice = await makeState(user: "alice", api: api, cookie: "session=rotated")
        XCTAssertNotNil(try AnalysisRepository(state: rotatedAlice, api: api, directory: folder)
            .cached(owner: aliceOwner, revision: rotatedAlice.authenticationRevision))
    }

    @MainActor
    func testAIUsesExplicitRequestAndDeletionEvictsOnlySelectedTerm() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = ###"{"term_id":8,"content":"## 报告","provider":"test","model":"model","created_at":"2026-09-08T10:00:00","cached":false}"###
        let api = AnalysisAPIStub(responses: [
            "/api/v1/terms": terms,
            "/api/v1/grades?term_id=8": grades,
            "/api/v1/grades/summary?term_id=8": summary,
            "/api/v1/grades/ai-analyses?term_id=8": "[]",
            "/api/v1/grades/ai-analysis?term_id=8&force_refresh=true": result,
            "/api/v1/grades?term_id=8#DELETE": #"{"term_id":8,"grades_deleted":1,"analyses_deleted":1}"#
        ])
        let state = await makeState(user: "alice", api: api)
        let revision = state.authenticationRevision
        let owner = try state.requireCurrentAccount(revision: revision)
        let repo = AnalysisRepository(state: state, api: api, directory: folder)
        _ = try await repo.refresh(owner: owner, revision: revision)
        XCTAssertFalse(api.paths.contains(where: { $0.contains("ai-analysis?") }),
                       "普通加载不能主动生成 AI 报告")
        let generated = try await repo.analyze(termID: 8, force: true)
        XCTAssertEqual(generated.content, "## 报告")
        try await repo.deleteGrades(termID: 8, owner: owner, revision: revision)
        XCTAssertNil(try repo.cached(owner: owner, revision: revision)?.byTerm[8])
        XCTAssertTrue(api.paths.contains("/api/v1/grades?term_id=8#DELETE"))
    }

    @MainActor
    private func makeState(user: String, api: AnalysisAPIStub, cookie: String? = nil) async -> AppState {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let state = AppState(api: api, sessionStore: AnalysisSessionStub(cookie: cookie ?? "session=\(user)"),
                             authentication: AnalysisAuthStub(user: user), preferences: preferences)
        await state.restoreSession()
        return state
    }
}

private final class AnalysisAPIStub: APIClientProtocol {
    let responses: [String: String]
    var paths: [String] = []
    init(responses: [String: String]) { self.responses = responses }
    func request<Value: Decodable>(_ method: String, path: String, body: Data?,
                                    preserveSessionOnPasswordError: Bool) async throws -> Value {
        let key = method == "DELETE" ? path + "#DELETE" : path
        paths.append(key)
        guard let response = responses[key] else { throw APIError.invalidResponse }
        return try JSONDecoder().decode(Value.self, from: Data(response.utf8))
    }
}

private final class AnalysisSessionStub: SessionStore {
    var cookie: String?
    init(cookie: String) { self.cookie = cookie }
    func save(cookie: String) { self.cookie = cookie }
    @discardableResult func clear() -> Bool { cookie = nil; return true }
}

private final class AnalysisAuthStub: AuthenticationClientProtocol {
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
