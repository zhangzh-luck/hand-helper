import Foundation

@MainActor
protocol AnalysisRepositoryProtocol {
    func cached(owner: String, revision: Int) throws -> AnalysisSnapshot?
    func refresh(owner: String, revision: Int) async throws -> AnalysisSnapshot
    func analyze(termID: Int, force: Bool) async throws -> GradeAIAnalysis
    func deleteGrades(termID: Int, owner: String, revision: Int) async throws
}

@MainActor
final class AnalysisRepository: AnalysisRepositoryProtocol {
    private struct CacheDocument: Codable {
        let version: Int
        let owner: String
        let baseURL: String
        let snapshot: AnalysisSnapshot
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

    private var file: URL { directory.appendingPathComponent("analysis_native_snapshot_v1.json") }

    func cached(owner: String, revision: Int) throws -> AnalysisSnapshot? {
        guard try state.requireCurrentAccount(revision: revision) == owner else { return nil }
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let document = try JSONDecoder().decode(CacheDocument.self, from: Data(contentsOf: file))
        guard document.version == 1, document.owner == owner,
              document.baseURL == baseURL.absoluteString else { return nil }
        return document.snapshot
    }

    func refresh(owner: String, revision: Int) async throws -> AnalysisSnapshot {
        guard try state.requireCurrentAccount(revision: revision) == owner else {
            throw APIError.unauthorized(message: "账号已变化")
        }
        let terms: [TermInfo] = try await api.request("GET", path: "/api/v1/terms", body: nil,
                                                      preserveSessionOnPasswordError: false)
        var byTerm: [Int: AnalysisTermData] = [:]
        for term in terms {
            try Task.checkCancellation()
            let path = "?term_id=\(term.id)"
            let grades: [GradeRecord] = try await api.request("GET", path: "/api/v1/grades" + path,
                                                              body: nil, preserveSessionOnPasswordError: false)
            let summary: GradeSummary = try await api.request("GET", path: "/api/v1/grades/summary" + path,
                                                               body: nil, preserveSessionOnPasswordError: false)
            let history: [GradeAIAnalysis] = try await api.request("GET", path: "/api/v1/grades/ai-analyses" + path,
                                                                   body: nil, preserveSessionOnPasswordError: false)
            byTerm[term.id] = AnalysisTermData(grades: grades, summary: summary, history: history)
        }
        guard try state.requireCurrentAccount(revision: revision) == owner else {
            throw APIError.unauthorized(message: "账号已变化")
        }
        let snapshot = AnalysisSnapshot(terms: terms, byTerm: byTerm, savedAt: Date())
        try save(snapshot, owner: owner)
        return snapshot
    }

    func analyze(termID: Int, force: Bool) async throws -> GradeAIAnalysis {
        let path = "/api/v1/grades/ai-analysis?term_id=\(termID)" + (force ? "&force_refresh=true" : "")
        return try await api.request("POST", path: path, body: nil,
                                     preserveSessionOnPasswordError: false)
    }

    func deleteGrades(termID: Int, owner: String, revision: Int) async throws {
        guard try state.requireCurrentAccount(revision: revision) == owner else {
            throw APIError.unauthorized(message: "账号已变化")
        }
        let _: GradeDeletionResult = try await api.request("DELETE", path: "/api/v1/grades?term_id=\(termID)",
                                                            body: nil, preserveSessionOnPasswordError: false)
        // Keep a successful server deletion from reappearing through the offline cache.
        if let document = try? JSONDecoder().decode(CacheDocument.self, from: Data(contentsOf: file)),
           document.version == 1, document.owner == owner,
           document.baseURL == baseURL.absoluteString {
            var snapshot = document.snapshot
            snapshot.byTerm.removeValue(forKey: termID)
            do { try save(snapshot, owner: owner) }
            catch { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func save(_ snapshot: AnalysisSnapshot, owner: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = CacheDocument(version: 1, owner: owner,
                                     baseURL: baseURL.absoluteString, snapshot: snapshot)
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
    }
}

private struct GradeDeletionResult: Decodable {
    let termID: Int
    enum CodingKeys: String, CodingKey { case termID = "term_id" }
}
