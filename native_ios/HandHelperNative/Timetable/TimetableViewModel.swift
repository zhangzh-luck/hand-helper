import Foundation
import SwiftUI

@MainActor
final class TimetableViewModel: ObservableObject {
    @Published private(set) var snapshot: CourseSnapshot?
    @Published private(set) var projection: WeeklyTimetableProjection?
    @Published private(set) var selectedTermID: Int?
    @Published private(set) var selectedWeek = 1
    @Published private(set) var snapshotRevision = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    private let state: AppState
    private let repository: any CourseRepository
    private let calendar: Calendar
    private let now: () -> Date
    private var appliedSequence: Int?
    /// Identifies the in-memory snapshot that was read for the current verified account.
    /// This is deliberately invalidated by account changes and course invalidations; it is
    /// not a permanent "has loaded" switch.
    private var cachedTicket: WeeklyTimetableAccountTicket?
    private var appliedLocalManualCourseSequence: Int?
    private var operation = 0

    init(state: AppState, repository: any CourseRepository, calendar: Calendar = .current,
         now: @escaping () -> Date = Date.init) {
        self.state = state
        self.repository = repository
        self.calendar = calendar
        self.now = now
    }

    var tabSwitchDiagnostics: TabSwitchDiagnostics { state.tabSwitchDiagnostics }
    var terms: [TermInfo] { snapshot?.terms ?? [] }
    var periods: [PeriodInfo] { snapshot?.periods.sorted { $0.periodNumber < $1.periodNumber } ?? [] }

    var isCurrentWeek: Bool {
        guard let term = terms.first(where: { $0.id == selectedTermID }),
              case .week(let week) = TeachingWeekCalendar.position(on: now(), term: term, calendar: calendar) else {
            return false
        }
        return selectedWeek == week
    }

    func clear() {
        operation += 1
        snapshotRevision += 1
        snapshot = nil
        projection = nil
        selectedTermID = nil
        selectedWeek = 1
        appliedSequence = nil
        cachedTicket = nil
        appliedLocalManualCourseSequence = nil
        errorMessage = nil
        isLoading = false
    }

    @discardableResult
    func loadCached() -> Bool {
        guard state.canAccessPrivateData else {
            clear()
            return false
        }
        do {
            let ticket = try access.ticket()
            guard let cached = try repository.cached() else {
                cachedTicket = nil
                return false
            }
            try accept(cached, ticket: ticket)
            cachedTicket = ticket
            if projection != nil, errorMessage != nil { errorMessage = nil }
            return snapshot != nil
        } catch {
            cachedTicket = nil
            if !state.canAccessPrivateData { clear() }
            else { errorMessage = "无法读取本机课程：\(error.localizedDescription)" }
            return false
        }
    }

    func addManualCourse(_ draft: ManualCourseDraft, from cell: TimetableEmptyCellSelection) throws {
        guard state.selectedTab == .timetable, !isLoading,
              selectedTermID == cell.termID, selectedWeek == cell.week,
              snapshotRevision == cell.snapshotRevision,
              try state.requireCurrentAccount(revision: cell.authenticationRevision) == cell.owner else {
            throw APIError.unauthorized(message: "课表或账号已变化，请重新选择空白节次。")
        }
        _ = try repository.createManualRule(termID: cell.termID, name: draft.name,
            weeks: Array(draft.weeks), weekday: draft.weekday,
            startPeriod: draft.startPeriod, endPeriod: draft.endPeriod,
            room: draft.room, teacher: draft.teacher)
        loadCached()
        try state.publishLocalManualCourseChange(for: cell.owner,
            authenticationRevision: cell.authenticationRevision)
        markCurrentLocalManualCourseChangeApplied()
    }

    func editableManualCourse(for course: CourseSession,
                              context: TimetableDetailContext) -> TimetableManualCourseIdentity? {
        guard state.selectedTab == .timetable, state.canAccessPrivateData,
              course.source == "LOCAL", let ruleID = course.manualCourseID,
              course.id == context.courseID, course.termID == context.termID,
              selectedTermID == context.termID, selectedWeek == context.week,
              snapshotRevision == context.snapshotRevision,
              let snapshot, let term = snapshot.terms.first(where: { $0.id == context.termID }),
              snapshot.manualRules.contains(where: {
                  $0.id == ruleID && $0.termSourceID == term.sourceTermID && $0.remoteID == nil
              }),
              let owner = try? state.requireCurrentAccount(revision: context.authenticationRevision) else {
            return nil
        }
        return TimetableManualCourseIdentity(owner: owner, ruleID: ruleID)
    }

    func manualRule(for request: TimetableManualCourseActionRequest) -> ManualCourseRule? {
        guard state.selectedTab == .timetable, !isLoading,
              selectedTermID == request.context.termID, selectedWeek == request.context.week,
              snapshotRevision == request.context.snapshotRevision,
              (try? state.requireCurrentAccount(revision: request.context.authenticationRevision)) == request.identity.owner,
              let snapshot, let term = snapshot.terms.first(where: { $0.id == request.context.termID }) else {
            return nil
        }
        return snapshot.manualRules.first {
            $0.id == request.identity.ruleID && $0.termSourceID == term.sourceTermID && $0.remoteID == nil
        }
    }

    func updateManualCourse(_ draft: ManualCourseDraft,
                            for request: TimetableManualCourseActionRequest) throws {
        guard manualRule(for: request) != nil else {
            throw APIError.unauthorized(message: "课表或账号已变化，请重新打开课程详情。")
        }
        _ = try repository.updateManualRule(id: request.identity.ruleID,
            termID: request.context.termID, name: draft.name, weeks: Array(draft.weeks),
            weekday: draft.weekday, startPeriod: draft.startPeriod,
            endPeriod: draft.endPeriod, room: draft.room, teacher: draft.teacher)
        loadCached()
        try state.publishLocalManualCourseChange(for: request.identity.owner,
            authenticationRevision: request.context.authenticationRevision)
        markCurrentLocalManualCourseChangeApplied()
    }

    func deleteManualCourse(for request: TimetableManualCourseActionRequest) throws {
        guard manualRule(for: request) != nil else {
            throw APIError.unauthorized(message: "课表或账号已变化，请重新打开课程详情。")
        }
        try repository.deleteManualRule(id: request.identity.ruleID,
                                        termID: request.context.termID)
        loadCached()
        try state.publishLocalManualCourseChange(for: request.identity.owner,
            authenticationRevision: request.context.authenticationRevision)
        markCurrentLocalManualCourseChangeApplied()
    }

    func selectTerm(_ id: Int) {
        guard terms.contains(where: { $0.id == id }) else { return }
        selectedTermID = id
        jumpToCurrentWeek()
    }

    func moveWeek(_ delta: Int) {
        selectWeek(selectedWeek + delta)
    }

    func selectWeek(_ week: Int) {
        guard (1...999).contains(week), selectedTermID != nil, week != selectedWeek else { return }
        selectedWeek = week
        reproject()
    }

    func projection(for week: Int) -> WeeklyTimetableProjection? {
        guard (1...999).contains(week), let snapshot, let selectedTermID else { return nil }
        guard let ticket = try? access.ticket() else { return nil }
        return try? access.project(snapshot, termID: selectedTermID, week: week,
                                   calendar: calendar, ticket: ticket)
    }

    func jumpToCurrentWeek() {
        guard let term = terms.first(where: { $0.id == selectedTermID }) else { return }
        if case .week(let week) = TeachingWeekCalendar.position(on: now(), term: term, calendar: calendar) {
            selectedWeek = week
        } else {
            selectedWeek = 1
        }
        reproject()
    }

    func updateIfNeeded(onCacheRestored: ((Bool) -> Void)? = nil,
                        diagnostics: TabSwitchDiagnostics? = nil) async {
        diagnostics?.record(.timetableUpdateBegin, for: .timetable)
        defer { diagnostics?.record(.timetableUpdateEnd, for: .timetable) }
        guard state.selectedTab == .timetable, state.canAccessPrivateData else { return }
        let marker = state.pendingCourseInvalidation(after: appliedSequence)
        let cacheAvailable: Bool
        if canReuseInMemorySnapshot(marker: marker) {
            cacheAvailable = true
        } else {
            cacheAvailable = loadCached()
        }
        onCacheRestored?(cacheAvailable)
        if let marker, state.completedCourseRefresh == marker {
            if snapshot != nil { appliedSequence = marker.sequence }
            return
        }
        if marker == nil && snapshot != nil { return }
        await refresh(marker: marker)
    }

    func refreshManually() async {
        guard state.selectedTab == .timetable else { return }
        await refresh(marker: state.pendingCourseInvalidation(after: appliedSequence))
    }

    private var access: WeeklyTimetableSnapshotAccess {
        WeeklyTimetableSnapshotAccess(state: state, repository: repository)
    }

    private func accept(_ newSnapshot: CourseSnapshot, ticket: WeeklyTimetableAccountTicket) throws {
        _ = try state.requireCurrentAccount(revision: ticket.authenticationRevision)
        let oldTerm = selectedTermID
        let contentChanged = snapshot != newSnapshot
        let nextTerm = oldTerm.flatMap { id in newSnapshot.terms.contains(where: { $0.id == id }) ? id : nil }
            ?? newSnapshot.terms.first(where: \.isCurrent)?.id ?? newSnapshot.terms.first?.id
        guard contentChanged || nextTerm != oldTerm else { return }
        if contentChanged {
            snapshot = newSnapshot
            snapshotRevision += 1
        }
        if nextTerm != oldTerm {
            selectedTermID = nextTerm
            jumpToCurrentWeek()
        } else {
            reproject()
        }
    }

    /// Applies a local edit notification only when it was not produced by this model's
    /// immediately preceding durable cache reload.
    func applyLocalManualCourseChange(_ change: LocalManualCourseChange) {
        guard (try? state.requireCurrentAccount(revision: change.authenticationRevision)) == change.owner else {
            return
        }
        guard appliedLocalManualCourseSequence != change.sequence else { return }
        _ = loadCached()
        appliedLocalManualCourseSequence = change.sequence
    }

    private func markCurrentLocalManualCourseChangeApplied() {
        appliedLocalManualCourseSequence = state.localManualCourseChange?.sequence
    }

    private func canReuseInMemorySnapshot(marker: CourseDataInvalidation?) -> Bool {
        guard marker == nil, snapshot != nil,
              let cachedTicket,
              let ticket = try? access.ticket(), ticket == cachedTicket else {
            return false
        }
        return true
    }

    private func reproject() {
        guard let snapshot, let selectedTermID else { projection = nil; return }
        do {
            let ticket = try access.ticket()
            let next = try access.project(snapshot, termID: selectedTermID, week: selectedWeek,
                                          calendar: calendar, ticket: ticket)
            projection = next
            if projection != nil { errorMessage = nil }
        } catch WeeklyTimetableError.missingStartDate {
            projection = nil
            errorMessage = "该学期尚未设置第一周日期。"
        } catch WeeklyTimetableError.invalidStartDate {
            projection = nil
            errorMessage = "该学期的第一周日期无效。"
        } catch {
            projection = nil
            errorMessage = "无法显示本周课程：\(error.localizedDescription)"
        }
    }

    private func refresh(marker: CourseDataInvalidation?) async {
        guard !isLoading, state.canAccessPrivateData, state.selectedTab == .timetable else { return }
        guard let ticket = try? access.ticket() else { clear(); return }
        operation += 1
        let request = operation
        isLoading = true
        defer { if operation == request { isLoading = false } }
        do {
            let fresh = try await repository.refreshStrict(on: now(), isCurrent: { [weak self] in
                guard let self else { return false }
                return self.operation == request && self.state.selectedTab == .timetable &&
                    self.state.authenticationRevision == ticket.authenticationRevision &&
                    (try? self.state.requireCurrentAccount(revision: ticket.authenticationRevision)) == ticket.owner &&
                    (marker == nil || self.state.courseDataInvalidation == marker)
            })
            guard operation == request, state.selectedTab == .timetable,
                  (try? state.requireCurrentAccount(revision: ticket.authenticationRevision)) == ticket.owner else { return }
            try accept(fresh, ticket: ticket)
            try? state.courseSnapshotDidChange(revision: ticket.authenticationRevision)
            if let marker, state.courseDataInvalidation == marker {
                state.acknowledgeCourseRefresh(marker)
                appliedSequence = marker.sequence
            }
            if projection != nil { errorMessage = nil }
        } catch {
            guard operation == request,
                  (try? state.requireCurrentAccount(revision: ticket.authenticationRevision)) == ticket.owner else { return }
            if let apiError = error as? APIError, case .unauthorized = apiError {
                state.handleUnauthorized()
                clear()
            } else {
                errorMessage = "课程刷新失败，仍显示本账号已缓存的课程：\(error.localizedDescription)"
            }
        }
    }
}
