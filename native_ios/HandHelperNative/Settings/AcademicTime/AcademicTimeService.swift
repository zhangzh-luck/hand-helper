import Foundation

struct AcademicTimeWriteResponse: Decodable, Equatable {
    let sessionsGenerated: Int
    enum CodingKeys: String, CodingKey { case sessionsGenerated = "sessions_generated" }
}

enum AcademicTimeSaveOutcome: Equatable {
    case confirmed(sessionsGenerated: Int)
    case unconfirmed
}

enum AcademicTimeWriteTarget: Equatable {
    case term(id: Int, startDate: String)
    case period(number: Int, start: String, end: String)

    var key: String {
        switch self {
        case .term(let id, _): return "term:\(id)"
        case .period(let number, _, _): return "period:\(number)"
        }
    }

    var title: String {
        switch self {
        case .term: return "学期第一周"
        case .period(let number, _, _): return "第 \(number) 节时间"
        }
    }
}

@MainActor
struct AcademicTimeService {
    let api: any APIClientProtocol

    func terms() async throws -> [TermInfo] {
        try await api.request("GET", path: "/api/v1/terms", body: nil, preserveSessionOnPasswordError: false)
    }

    func periods() async throws -> [PeriodInfo] {
        try await api.request("GET", path: "/api/v1/settings/period-times", body: nil,
                              preserveSessionOnPasswordError: false)
    }

    func write(_ target: AcademicTimeWriteTarget) async throws -> AcademicTimeWriteResponse {
        switch target {
        case .term(let id, let startDate):
            let body = try JSONEncoder().encode(TermStartRequest(startDate: startDate))
            return try await api.request("PUT", path: "/api/v1/terms/\(id)/start-date",
                                         body: body, preserveSessionOnPasswordError: false)
        case .period(let number, let start, let end):
            let body = try JSONEncoder().encode(PeriodTimeRequest(startTime: start, endTime: end))
            return try await api.request("PUT", path: "/api/v1/settings/period-times/\(number)",
                                         body: body, preserveSessionOnPasswordError: false)
        }
    }

    func confirms(_ target: AcademicTimeWriteTarget) async throws -> Bool {
        switch target {
        case .term(let id, let startDate):
            let actual = try await terms()
            return actual.first(where: { $0.id == id })?.startDate == startDate
        case .period(let number, let start, let end):
            let actual = try await periods()
            return actual.first(where: { $0.periodNumber == number }).map {
                $0.startTime == start && $0.endTime == end
            } == true
        }
    }

    // Kept as a focused service operation for callers that do not need pending-write recovery.
    func saveTerm(id: Int, startDate: String, isCurrent: () -> Bool = { true }) async throws -> AcademicTimeSaveOutcome {
        try await save(.term(id: id, startDate: startDate), isCurrent: isCurrent)
    }

    func savePeriod(number: Int, start: String, end: String, isCurrent: () -> Bool = { true }) async throws -> AcademicTimeSaveOutcome {
        try await save(.period(number: number, start: start, end: end), isCurrent: isCurrent)
    }

    private func save(_ target: AcademicTimeWriteTarget, isCurrent: () -> Bool) async throws -> AcademicTimeSaveOutcome {
        let written = try await write(target)
        guard !Task.isCancelled, isCurrent() else {
            throw APIError.unauthorized(message: "登录状态已变化")
        }
        do {
            let matches = try await confirms(target)
            return matches ? .confirmed(sessionsGenerated: written.sessionsGenerated) : .unconfirmed
        } catch let error as APIError {
            if case .unauthorized = error { throw error }
            return .unconfirmed
        } catch { return .unconfirmed }
    }
}

private struct TermStartRequest: Encodable {
    let startDate: String
    enum CodingKeys: String, CodingKey { case startDate = "start_date" }
}

private struct PeriodTimeRequest: Encodable {
    let startTime: String
    let endTime: String
    enum CodingKeys: String, CodingKey { case startTime = "start_time", endTime = "end_time" }
}