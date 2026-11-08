import Foundation
import SwiftUI

@MainActor
final class AnalysisViewModel: ObservableObject {
    @Published private(set) var snapshot: AnalysisSnapshot?
    @Published private(set) var selectedTermID: Int?
    @Published private(set) var loading = false
    @Published private(set) var refreshing = false
    @Published private(set) var offline = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var actionError: String?
    @Published private(set) var analyzing = false
    @Published private(set) var deleting = false
    @Published private(set) var currentAnalysis: GradeAIAnalysis?
    @Published private(set) var analysisJob: GradeAIJob?
    @Published private(set) var recoveringAnalysisJob = false

    private let state: AppState
    private let repository: any AnalysisRepositoryProtocol
    private var owner: String?
    private var generation = 0
    /// Refreshing grades must not invalidate a durable AI-job poll. These are
    /// deliberately separate because a refresh can fail while a server job is
    /// still running and recoverable.
    private var refreshGeneration = 0
    private var attemptedOnline = false
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var persistedJobs: [PersistedGradeAIJob] = []
    private var visible = true

    init(state: AppState, repository: (any AnalysisRepositoryProtocol)? = nil) {
        self.state = state
        self.repository = repository ?? AnalysisRepository(state: state)
    }

    var selectedTerm: TermInfo? { snapshot?.terms.first(where: { $0.id == selectedTermID }) }

    var selectedData: AnalysisTermData? {
        guard let selectedTermID else { return nil }
        return snapshot?.byTerm[selectedTermID]
    }

    var analysisStatusText: String? {
        if recoveringAnalysisJob { return "正在恢复分析任务" }
        guard let analysisJob else { return nil }
        if let message = analysisJob.errorMessage, !message.isEmpty, !analysisJob.status.isActive {
            return message
        }
        return analysisJob.status.displayName
    }

    var canCancelAnalysisJob: Bool { analysisJob?.status.isActive == true && !recoveringAnalysisJob }
    var analysisJobNeedsManualAttention: Bool {
        analysisJob?.status == .unknown && !recoveringAnalysisJob
    }

    func loadIfNeeded() {
        guard state.selectedTab == .analysis, state.canAccessPrivateData else { return }
        let revision = state.authenticationRevision
        guard let currentOwner = try? state.requireCurrentAccount(revision: revision) else { return }
        if owner != currentOwner { reset(); owner = currentOwner }
        loadPersistedJobs(owner: currentOwner, revision: revision)
        if snapshot == nil {
            do {
                snapshot = try repository.cached(owner: currentOwner, revision: revision)
                selectDefaultTerm()
            } catch {
                errorMessage = "本机成绩缓存无法读取：\(error.localizedDescription)"
            }
        }
        restoreSelectedTermJob(owner: currentOwner, revision: revision)
        if !attemptedOnline && refreshTask == nil { refresh() }
    }

    func selectTerm(_ id: Int) {
        guard snapshot?.terms.contains(where: { $0.id == id }) == true else { return }
        stopPolling()
        selectedTermID = id
        currentAnalysis = nil
        analysisJob = nil
        recoveringAnalysisJob = false
        analyzing = false
        actionError = nil
        guard let owner,
              let currentOwner = try? state.requireCurrentAccount(revision: state.authenticationRevision),
              owner == currentOwner else { return }
        restoreSelectedTermJob(owner: owner, revision: state.authenticationRevision)
    }

    func refresh() {
        guard !refreshing, state.selectedTab == .analysis,
              let currentOwner = try? state.requireCurrentAccount(revision: state.authenticationRevision) else { return }
        let revision = state.authenticationRevision
        attemptedOnline = true
        refreshGeneration += 1
        let refreshToken = refreshGeneration
        refreshing = true
        loading = snapshot == nil
        refreshTask = Task {
            defer {
                if refreshGeneration == refreshToken {
                    refreshing = false
                    loading = false
                    refreshTask = nil
                }
            }
            do {
                let fresh = try await repository.refresh(owner: currentOwner, revision: revision)
                guard isCurrentRefresh(owner: currentOwner, revision: revision, token: refreshToken) else { return }
                snapshot = fresh
                offline = false
                errorMessage = nil
                selectDefaultTerm()
                restoreSelectedTermJob(owner: currentOwner, revision: revision)
            } catch {
                guard isCurrentRefresh(owner: currentOwner, revision: revision, token: refreshToken) else { return }
                offline = true
                errorMessage = error.localizedDescription
            }
        }
    }

    func generateAnalysis(force: Bool = false, completion: @escaping (GradeAIAnalysis) -> Void) {
        guard !analyzing, !refreshing, !offline, let termID = selectedTermID,
              selectedData?.grades.isEmpty == false,
              let currentOwner = try? state.requireCurrentAccount(revision: state.authenticationRevision) else { return }
        let revision = state.authenticationRevision
        let token = generation
        let persisted = PersistedGradeAIJob(termID: termID,
                                            idempotencyKey: "native-grade-ai-v1-\(UUID().uuidString.lowercased())",
                                            forceRefresh: force, job: nil, createdAt: Date())
        do { try persist(persisted, owner: currentOwner, revision: revision) }
        catch { actionError = error.localizedDescription; return }
        actionError = nil
        recoveringAnalysisJob = true
        analyzing = true
        submit(persisted, owner: currentOwner, revision: revision, token: token, completion: completion)
    }

    /// Hiding the view only stops local polling. The durable server task stays active.
    func visibilityDidChange(_ isVisible: Bool) {
        visible = isVisible
        if !isVisible { stopPolling(); return }
        loadIfNeeded()
    }

    func cancelAnalysis() {
        guard let job = analysisJob, job.status.isActive,
              let currentOwner = try? state.requireCurrentAccount(revision: state.authenticationRevision) else { return }
        let revision = state.authenticationRevision
        let token = generation
        analyzing = true
        actionError = nil
        Task {
            do {
                let cancelled = try await repository.cancelAnalysisJob(id: job.jobID)
                guard isCurrent(owner: currentOwner, revision: revision, token: token) else { return }
                receive(cancelled, owner: currentOwner, revision: revision, token: token, completion: nil)
            } catch {
                guard isCurrent(owner: currentOwner, revision: revision, token: token) else { return }
                analyzing = false
                actionError = "无法确认取消结果：\(error.localizedDescription)"
            }
        }
    }

    /// Replays an unacknowledged create request with the same idempotency key,
    /// or resumes polling a known server job. It never creates a fresh key.
    func resumeAnalysisJob() {
        guard !analyzing, let termID = selectedTermID,
              let persisted = persistedJobs.first(where: { $0.termID == termID }),
              let currentOwner = try? state.requireCurrentAccount(revision: state.authenticationRevision) else { return }
        actionError = nil
        recoveringAnalysisJob = true
        analyzing = true
        if let job = persisted.job {
            analysisJob = job
            poll(jobID: job.jobID, owner: currentOwner, revision: state.authenticationRevision,
                 token: generation, completion: nil)
        } else {
            submit(persisted, owner: currentOwner, revision: state.authenticationRevision,
                   token: generation, completion: { _ in })
        }
    }

    func deleteSelectedTerm(_ termID: Int) {
        guard !deleting, !analyzing, !recoveringAnalysisJob, !refreshing, !offline, selectedTermID == termID,
              selectedData?.grades.isEmpty == false,
              let currentOwner = try? state.requireCurrentAccount(revision: state.authenticationRevision) else { return }
        let revision = state.authenticationRevision
        let token = generation
        deleting = true
        actionError = nil
        Task {
            defer { if generation == token { deleting = false } }
            do {
                try await repository.deleteGrades(termID: termID, owner: currentOwner, revision: revision)
                guard isCurrent(owner: currentOwner, revision: revision, token: token), selectedTermID == termID else { return }
                snapshot?.byTerm.removeValue(forKey: termID)
                currentAnalysis = nil
                analysisJob = nil
                deleting = false
                refresh()
            } catch {
                guard isCurrent(owner: currentOwner, revision: revision, token: token) else { return }
                actionError = error.localizedDescription
            }
        }
    }

    func authenticationDidChange() {
        reset()
        if state.selectedTab == .analysis { loadIfNeeded() }
    }

    private func submit(_ persisted: PersistedGradeAIJob, owner: String, revision: Int,
                        token: Int, completion: @escaping (GradeAIAnalysis) -> Void) {
        Task {
            do {
                let job = try await repository.createAnalysisJob(termID: persisted.termID,
                                                                  force: persisted.forceRefresh,
                                                                  idempotencyKey: persisted.idempotencyKey)
                guard isCurrent(owner: owner, revision: revision, token: token) else { return }
                let saved = PersistedGradeAIJob(termID: persisted.termID,
                                                idempotencyKey: persisted.idempotencyKey,
                                                forceRefresh: persisted.forceRefresh,
                                                job: job, createdAt: persisted.createdAt)
                try persist(saved, owner: owner, revision: revision)
                receive(job, owner: owner, revision: revision, token: token, completion: completion)
                if job.status.isActive, visible {
                    poll(jobID: job.jobID, owner: owner, revision: revision,
                         token: token, completion: completion)
                }
            } catch {
                guard isCurrent(owner: owner, revision: revision, token: token) else { return }
                analyzing = false
                recoveringAnalysisJob = true
                if let apiError = error as? APIError,
                   case .server(let status, _) = apiError, status == 409 {
                    removePersisted(id: persisted.id, owner: owner, revision: revision)
                    recoveringAnalysisJob = false
                }
                actionError = error.localizedDescription
            }
        }
    }

    private func restoreSelectedTermJob(owner: String, revision: Int) {
        guard let termID = selectedTermID,
              let persisted = persistedJobs.first(where: { $0.termID == termID }) else { return }
        if let job = persisted.job {
            analysisJob = job
            if job.status.isActive, visible {
                analyzing = true
                poll(jobID: job.jobID, owner: owner, revision: revision, token: generation, completion: nil)
            } else if !job.status.isActive {
                receive(job, owner: owner, revision: revision, token: generation, completion: nil)
            }
        } else {
            recoveringAnalysisJob = true
            analyzing = true
            if visible {
                submit(persisted, owner: owner, revision: revision, token: generation, completion: { _ in })
            }
        }
    }

    private func poll(jobID: String, owner: String, revision: Int, token: Int,
                      completion: ((GradeAIAnalysis) -> Void)?) {
        stopPolling()
        pollingTask = Task {
            while !Task.isCancelled {
                do {
                    let job = try await repository.analysisJob(id: jobID)
                    guard isCurrent(owner: owner, revision: revision, token: token), selectedTermID == job.termID else { return }
                    receive(job, owner: owner, revision: revision, token: token, completion: completion)
                    guard job.status.isActive else { return }
                    try await Task.sleep(for: .seconds(2))
                } catch is CancellationError {
                    return
                } catch {
                    guard isCurrent(owner: owner, revision: revision, token: token) else { return }
                    analyzing = false
                    recoveringAnalysisJob = true
                    actionError = "暂时无法获取分析状态：\(error.localizedDescription)"
                    return
                }
            }
        }
    }

    private func receive(_ job: GradeAIJob, owner: String, revision: Int, token: Int,
                         completion: ((GradeAIAnalysis) -> Void)?) {
        analysisJob = job
        recoveringAnalysisJob = false
        guard let matching = persistedJobs.first(where: { $0.job?.jobID == job.jobID }) else {
            analyzing = job.status.isActive
            return
        }
        if job.status.isActive {
            let updated = PersistedGradeAIJob(termID: matching.termID, idempotencyKey: matching.idempotencyKey,
                                              forceRefresh: matching.forceRefresh, job: job, createdAt: matching.createdAt)
            do { try persist(updated, owner: owner, revision: revision) }
            catch { actionError = error.localizedDescription }
            analyzing = true
            return
        }
        stopPolling()
        analyzing = false
        switch job.status {
        case .succeeded:
            removePersisted(id: matching.id, owner: owner, revision: revision)
            if let analysis = job.analysis {
                currentAnalysis = analysis
                actionError = nil
                if state.selectedTab == .analysis { completion?(analysis) }
                refresh()
            } else {
                actionError = "分析任务已完成，但报告暂不可用，请刷新后查看历史记录。"
            }
        case .failed, .cancelled:
            removePersisted(id: matching.id, owner: owner, revision: revision)
            actionError = job.errorMessage ?? job.status.displayName
        case .unknown:
            // An unknown server state is deliberately retained. The only next
            // action is an explicit status query using the existing job ID;
            // never create a fresh, potentially billable request automatically.
            actionError = job.errorMessage ?? job.status.displayName
        case .queued, .running:
            break
        }
    }

    private func loadPersistedJobs(owner: String, revision: Int) {
        do { persistedJobs = try repository.persistedJobs(owner: owner, revision: revision) }
        catch { actionError = "本机分析任务无法读取：\(error.localizedDescription)" }
    }

    private func persist(_ job: PersistedGradeAIJob, owner: String, revision: Int) throws {
        try repository.savePersistedJob(job, owner: owner, revision: revision)
        persistedJobs.removeAll { $0.id == job.id || ($0.termID == job.termID && $0.idempotencyKey == job.idempotencyKey) }
        persistedJobs.append(job)
    }

    private func removePersisted(id: String, owner: String, revision: Int) {
        do {
            try repository.removePersistedJob(id: id, owner: owner, revision: revision)
            persistedJobs.removeAll { $0.id == id }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func stopPolling() { pollingTask?.cancel(); pollingTask = nil }

    private func isCurrent(owner currentOwner: String, revision: Int, token: Int) -> Bool {
        generation == token && owner == currentOwner &&
            (try? state.requireCurrentAccount(revision: revision)) == currentOwner
    }

    private func isCurrentRefresh(owner currentOwner: String, revision: Int, token: Int) -> Bool {
        refreshGeneration == token && owner == currentOwner &&
            (try? state.requireCurrentAccount(revision: revision)) == currentOwner
    }

    private func selectDefaultTerm() {
        guard let terms = snapshot?.terms else { selectedTermID = nil; return }
        if let selectedTermID, terms.contains(where: { $0.id == selectedTermID }) { return }
        selectedTermID = terms.first(where: \.isCurrent)?.id ?? terms.last?.id
        currentAnalysis = nil
    }

    private func reset() {
        generation += 1
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        stopPolling()
        owner = nil
        snapshot = nil
        selectedTermID = nil
        loading = false
        refreshing = false
        offline = false
        attemptedOnline = false
        errorMessage = nil
        actionError = nil
        analyzing = false
        deleting = false
        currentAnalysis = nil
        analysisJob = nil
        recoveringAnalysisJob = false
        persistedJobs = []
    }
}
