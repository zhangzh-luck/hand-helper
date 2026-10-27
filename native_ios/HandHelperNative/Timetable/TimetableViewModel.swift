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
    private var operation = 0

    init(state: AppState, repository: any CourseRepository, calendar: Calendar = .current,
         now: @escaping () -> Date = Date.init) {
        self.state = state
        self.repository = repository
        self.calendar = calendar
        self.now = now
    }

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
        errorMessage = nil
        isLoading = false
    }

    func loadCached() {
        guard state.canAccessPrivateData else { clear(); return }
        do {
            let ticket = try access.ticket()
            guard let cached = try repository.cached() else { return }
            try accept(cached, ticket: ticket)
            if projection != nil { errorMessage = nil }
        } catch {
            if !state.canAccessPrivateData { clear() }
            else { errorMessage = "无法读取本机课程：\(error.localizedDescription)" }
        }
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

    func updateIfNeeded() async {
        guard state.selectedTab == .timetable, state.canAccessPrivateData else { return }
        loadCached()
        let marker = state.pendingCourseInvalidation(after: appliedSequence)
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
        snapshot = newSnapshot
        if contentChanged { snapshotRevision += 1 }
        selectedTermID = oldTerm.flatMap { id in newSnapshot.terms.contains(where: { $0.id == id }) ? id : nil }
            ?? newSnapshot.terms.first(where: \.isCurrent)?.id ?? newSnapshot.terms.first?.id
        if selectedTermID != oldTerm { jumpToCurrentWeek() }
        else { reproject() }
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
