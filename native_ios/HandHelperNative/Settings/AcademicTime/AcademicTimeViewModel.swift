import Foundation
import SwiftUI

enum AcademicTimeValidation {
    static func isMonday(_ date: Date, calendar: Calendar = .current) -> Bool {
        calendar.component(.weekday, from: date) == 2
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value)
    }

    static func timeString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func time(_ value: String, calendar: Calendar = .current) -> Date? {
        let parts = value.split(separator: ":")
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute))
    }

    static func validPeriod(start: String, end: String) -> Bool {
        time(start) != nil && time(end) != nil && start < end
    }
}

@MainActor
final class AcademicTimeViewModel: ObservableObject {
    @Published private(set) var terms: [TermInfo] = []
    @Published private(set) var periods: [PeriodInfo] = []
    @Published var selectedTermID: Int?
    @Published var selectedPeriodNumber: Int?
    @Published var firstMonday = Date()
    @Published var startTime = Date()
    @Published var endTime = Date()
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?

    private let service: AcademicTimeService
    private let state: AppState
    private var generation = 0

    init(state: AppState, service: AcademicTimeService) {
        self.state = state
        self.service = service
    }

    var selectedTerm: TermInfo? { terms.first { $0.id == selectedTermID } }
    var selectedPeriod: PeriodInfo? { periods.first { $0.periodNumber == selectedPeriodNumber } }
    var termIsDirty: Bool {
        guard let term = selectedTerm else { return false }
        return AcademicTimeValidation.dateString(firstMonday) != term.startDate
    }
    var periodIsDirty: Bool {
        guard let period = selectedPeriod else { return false }
        return AcademicTimeValidation.timeString(startTime) != period.startTime ||
            AcademicTimeValidation.timeString(endTime) != period.endTime
    }

    func selectTerm(_ id: Int?) {
        selectedTermID = id
        if let term = selectedTerm {
            firstMonday = AcademicTimeValidation.date(term.startDate) ?? Date()
        }
        errorMessage = nil
        statusMessage = nil
    }

    func selectPeriod(_ number: Int?) {
        selectedPeriodNumber = number
        if let period = selectedPeriod {
            startTime = AcademicTimeValidation.time(period.startTime) ?? Date()
            endTime = AcademicTimeValidation.time(period.endTime) ?? Date()
        }
        errorMessage = nil
        statusMessage = nil
    }

    func reset() {
        generation += 1
        isLoading = false
        isSaving = false
        terms = []
        periods = []
        selectedTermID = nil
        selectedPeriodNumber = nil
        errorMessage = nil
        statusMessage = nil
    }

    func load() async {
        guard !isLoading, !isSaving else { return }
        let revision = state.authenticationRevision
        guard (try? state.requireCurrentAccount(revision: revision)) != nil else { reset(); return }
        generation += 1
        let request = generation
        isLoading = true
        errorMessage = nil
        defer { if request == generation { isLoading = false } }
        do {
            let loadedTerms = try await service.terms()
            _ = try state.requireCurrentAccount(revision: revision)
            guard request == generation, !Task.isCancelled else { return }
            let loadedPeriods = try await service.periods()
            _ = try state.requireCurrentAccount(revision: revision)
            guard request == generation, !Task.isCancelled else { return }
            terms = loadedTerms
            periods = loadedPeriods
            selectTerm(loadedTerms.contains { $0.id == selectedTermID }
                ? selectedTermID : loadedTerms.first(where: { $0.isCurrent })?.id ?? loadedTerms.first?.id)
            selectPeriod(loadedPeriods.contains { $0.periodNumber == selectedPeriodNumber }
                ? selectedPeriodNumber : loadedPeriods.first?.periodNumber)
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func saveTerm() async {
        guard !isSaving, !isLoading, let term = selectedTerm else { return }
        guard AcademicTimeValidation.isMonday(firstMonday) else {
            errorMessage = "请选择星期一作为第一周的开始日期。"
            return
        }
        let date = AcademicTimeValidation.dateString(firstMonday)
        guard date != term.startDate else { return }
        await save(.term(id: term.id, startDate: date)) { count in
            if let index = terms.firstIndex(where: { $0.id == term.id }) {
                terms[index] = TermInfo(id: term.id, sourceTermID: term.sourceTermID,
                                        displayName: term.displayName, startDate: date, isCurrent: term.isCurrent)
            }
            statusMessage = "学期第一周已写入并读回确认；已生成 \(count) 条课程日程，已通知今日页刷新。"
        }
    }

    func savePeriod() async {
        guard !isSaving, !isLoading, let period = selectedPeriod else { return }
        let start = AcademicTimeValidation.timeString(startTime)
        let end = AcademicTimeValidation.timeString(endTime)
        guard AcademicTimeValidation.validPeriod(start: start, end: end) else {
            errorMessage = "下课时间必须晚于上课时间。"
            return
        }
        guard start != period.startTime || end != period.endTime else { return }
        await save(.period(number: period.periodNumber, start: start, end: end)) { count in
            if let index = periods.firstIndex(where: { $0.periodNumber == period.periodNumber }) {
                periods[index] = PeriodInfo(periodNumber: period.periodNumber, startTime: start, endTime: end)
            }
            statusMessage = "第 \(period.periodNumber) 节已写入并读回确认；已生成 \(count) 条课程日程，已通知今日页刷新。"
        }
    }

    private func save(_ target: AcademicTimeWriteTarget, onConfirmed: (Int) -> Void) async {
        let revision = state.authenticationRevision
        let owner: String
        let ticket: UUID
        do {
            owner = try state.requireCurrentAccount(revision: revision)
            ticket = try state.beginAcademicTimeWrite(target, revision: revision)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isSaving = true
        errorMessage = nil
        statusMessage = nil
        generation += 1
        let request = generation
        defer { if request == generation { isSaving = false } }
        do {
            let written = try await service.write(target)
            // The ticket was created before PUT; logout or another account clears it.
            guard state.acceptAcademicTimeWrite(ticket) else { return }
            await state.reconcilePendingAcademicTimeWrites()
            guard request == generation, !Task.isCancelled,
                  (try? state.requireCurrentAccount(revision: revision)) == owner else { return }
            if state.hasPendingAcademicTimeWrite(ticket) {
                statusMessage = "服务端已接受写入，但读回尚未确认。请使用「重新核对」；不会重复提交。"
            } else {
                onConfirmed(written.sessionsGenerated)
            }
        } catch {
            state.abandonAcademicTimeWrite(ticket)
            guard request == generation, !Task.isCancelled,
                  (try? state.requireCurrentAccount(revision: revision)) == owner else { return }
            errorMessage = error.localizedDescription
        }
    }
}