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

    private let state: AppState
    private let repository: any AnalysisRepositoryProtocol
    private var owner: String?
    private var generation = 0
    private var attemptedOnline = false
    private var refreshTask: Task<Void, Never>?

    init(state: AppState, repository: (any AnalysisRepositoryProtocol)? = nil) {
        self.state = state
        self.repository = repository ?? AnalysisRepository(state: state)
    }

    var selectedTerm: TermInfo? {
        snapshot?.terms.first(where: { $0.id == selectedTermID })
    }
    var selectedData: AnalysisTermData? {
        guard let selectedTermID else { return nil }
        return snapshot?.byTerm[selectedTermID]
    }

    func loadIfNeeded() {
        guard state.selectedTab == .analysis, state.canAccessPrivateData else { return }
        let revision = state.authenticationRevision
        guard let currentOwner = try? state.requireCurrentAccount(revision: revision) else { return }
        if owner != currentOwner { reset(); owner = currentOwner }
        if snapshot == nil {
            do {
                snapshot = try repository.cached(owner: currentOwner, revision: revision)
                selectDefaultTerm()
            } catch {
                errorMessage = "本机成绩缓存无法读取：\(error.localizedDescription)"
            }
        }
        if !attemptedOnline && refreshTask == nil { refresh() }
    }

    func selectTerm(_ id: Int) {
        guard snapshot?.terms.contains(where: { $0.id == id }) == true else { return }
        selectedTermID = id
        currentAnalysis = nil
        actionError = nil
    }

    func refresh() {
        guard !refreshing, state.selectedTab == .analysis,
              let currentOwner = try? state.requireCurrentAccount(revision: state.authenticationRevision) else { return }
        let revision = state.authenticationRevision
        attemptedOnline = true
        generation += 1
        let token = generation
        refreshing = true
        loading = snapshot == nil
        refreshTask = Task {
            defer { if generation == token { refreshing = false; loading = false; refreshTask = nil } }
            do {
                let fresh = try await repository.refresh(owner: currentOwner, revision: revision)
                guard isCurrent(owner: currentOwner, revision: revision, token: token) else { return }
                snapshot = fresh
                offline = false
                errorMessage = nil
                selectDefaultTerm()
            } catch {
                guard isCurrent(owner: currentOwner, revision: revision, token: token) else { return }
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
        analyzing = true
        actionError = nil
        Task {
            defer { if generation == token { analyzing = false } }
            do {
                let result = try await repository.analyze(termID: termID, force: force)
                guard isCurrent(owner: currentOwner, revision: revision, token: token),
                      selectedTermID == termID else { return }
                currentAnalysis = result
                completion(result)
                analyzing = false
                refresh()
            } catch {
                guard isCurrent(owner: currentOwner, revision: revision, token: token) else { return }
                actionError = error.localizedDescription
            }
        }
    }

    func deleteSelectedTerm(_ termID: Int) {
        guard !deleting, !analyzing, !refreshing, !offline, selectedTermID == termID,
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
                guard isCurrent(owner: currentOwner, revision: revision, token: token),
                      selectedTermID == termID else { return }
                snapshot?.byTerm.removeValue(forKey: termID)
                currentAnalysis = nil
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

    private func isCurrent(owner currentOwner: String, revision: Int, token: Int) -> Bool {
        generation == token && owner == currentOwner &&
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
        refreshTask?.cancel()
        refreshTask = nil
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
    }
}
