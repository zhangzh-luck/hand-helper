import Foundation

@MainActor
protocol AnalysisRepositoryProtocol {
    func cached(owner: String, revision: Int) throws -> AnalysisSnapshot?
    func refresh(owner: String, revision: Int) async throws -> AnalysisSnapshot
    func createAnalysisJob(termID: Int, force: Bool, idempotencyKey: String) async throws -> GradeAIJob
    func analysisJob(id: String) async throws -> GradeAIJob
    func cancelAnalysisJob(id: String) async throws -> GradeAIJob
    func persistedJobs(owner: String, revision: Int) throws -> [PersistedGradeAIJob]
    func savePersistedJob(_ job: PersistedGradeAIJob, owner: String, revision: Int) throws
    func removePersistedJob(id: String, owner: String, revision: Int) throws
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

    private struct JobScope: Codable {
        let owner: String
        let baseURL: String
        var jobs: [PersistedGradeAIJob]
    }

    private struct JobDocument: Codable {
        let version: Int
        var scopes: [JobScope]

        private enum CodingKeys: String, CodingKey {
            case version, scopes, owner, baseURL, jobs
        }

        init(scopes: [JobScope]) {
            self.version = 2
            self.scopes = scopes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(Int.self, forKey: .version)
            switch version {
            case 2:
                self.version = version
                self.scopes = try container.decode([JobScope].self, forKey: .scopes)
            case 1:
                // Preserve the first implementation's recovery record while
                // migrating it to independently scoped documents.
                self.version = 2
                self.scopes = [JobScope(owner: try container.decode(String.self, forKey: .owner),
                                        baseURL: try container.decode(String.self, forKey: .baseURL),
                                        jobs: try container.decode([PersistedGradeAIJob].self, forKey: .jobs))]
            default:
                throw DecodingError.dataCorruptedError(forKey: .version, in: container,
                                                       debugDescription: "Unsupported AI-job cache version")
            }
        }
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
    private var jobsFile: URL { directory.appendingPathComponent("analysis_native_ai_jobs_v1.json") }

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

    func createAnalysisJob(termID: Int, force: Bool, idempotencyKey: String) async throws -> GradeAIJob {
        let encodedKey = idempotencyKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? idempotencyKey
        let path = "/api/v1/grades/ai-analysis/jobs?term_id=\(termID)&force_refresh=\(force ? "true" : "false")&idempotency_key=\(encodedKey)"
        return try await api.request("POST", path: path, body: nil,
                                     preserveSessionOnPasswordError: false)
    }

    func analysisJob(id: String) async throws -> GradeAIJob {
        try await api.request("GET", path: "/api/v1/grades/ai-analysis/jobs/\(id)", body: nil,
                              preserveSessionOnPasswordError: false)
    }

    func cancelAnalysisJob(id: String) async throws -> GradeAIJob {
        try await api.request("POST", path: "/api/v1/grades/ai-analysis/jobs/\(id)/cancel", body: nil,
                              preserveSessionOnPasswordError: false)
    }

    func persistedJobs(owner: String, revision: Int) throws -> [PersistedGradeAIJob] {
        guard try state.requireCurrentAccount(revision: revision) == owner else { return [] }
        guard FileManager.default.fileExists(atPath: jobsFile.path) else { return [] }
        let document = try JSONDecoder().decode(JobDocument.self, from: Data(contentsOf: jobsFile))
        return document.scopes.first(where: { $0.owner == owner && $0.baseURL == baseURL.absoluteString })?.jobs ?? []
    }

    func savePersistedJob(_ job: PersistedGradeAIJob, owner: String, revision: Int) throws {
        guard try state.requireCurrentAccount(revision: revision) == owner else {
            throw APIError.unauthorized(message: "账号已变化")
        }
        var document = try loadJobsDocument()
        let index = document.scopes.firstIndex(where: { $0.owner == owner && $0.baseURL == baseURL.absoluteString })
        var jobs = index.map { document.scopes[$0].jobs } ?? []
        jobs.removeAll { $0.id == job.id || ($0.termID == job.termID && $0.idempotencyKey == job.idempotencyKey) }
        jobs.append(job)
        let scope = JobScope(owner: owner, baseURL: baseURL.absoluteString, jobs: jobs)
        if let index { document.scopes[index] = scope } else { document.scopes.append(scope) }
        try save(document)
    }

    func removePersistedJob(id: String, owner: String, revision: Int) throws {
        guard try state.requireCurrentAccount(revision: revision) == owner else {
            throw APIError.unauthorized(message: "账号已变化")
        }
        var document = try loadJobsDocument()
        guard let index = document.scopes.firstIndex(where: { $0.owner == owner && $0.baseURL == baseURL.absoluteString }) else { return }
        document.scopes[index].jobs.removeAll { $0.id == id }
        try save(document)
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

    private func loadJobsDocument() throws -> JobDocument {
        guard FileManager.default.fileExists(atPath: jobsFile.path) else { return JobDocument(scopes: []) }
        return try JSONDecoder().decode(JobDocument.self, from: Data(contentsOf: jobsFile))
    }

    private func save(_ document: JobDocument) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: jobsFile, options: .atomic)
    }
}

private struct GradeDeletionResult: Decodable {
    let termID: Int
    enum CodingKeys: String, CodingKey { case termID = "term_id" }
}
