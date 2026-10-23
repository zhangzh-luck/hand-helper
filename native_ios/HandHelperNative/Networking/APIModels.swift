import Foundation

/// The backend returns { success, data, error: { message } }.
struct APIEnvelope<Value: Decodable>: Decodable {
    let success: Bool
    let data: Value?
    let error: APIErrorPayload?
}

struct APIErrorPayload: Decodable {
    let message: String?
}

/// Use for successful endpoints whose `data` is null or absent.
struct APIEmptyResponse: Decodable, Equatable {
    init() {}
}

struct AuthIdentity: Codable, Equatable {
    let username: String
}

struct TermInfo: Codable, Equatable {
    let id: Int
    let sourceTermID: String
    let displayName: String
    let startDate: String?
    let isCurrent: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case sourceTermID = "source_term_id"
        case displayName = "display_name"
        case startDate = "start_date"
        case isCurrent = "is_current"
    }
}

struct PeriodInfo: Codable, Equatable {
    let periodNumber: Int
    let startTime: String
    let endTime: String

    enum CodingKeys: String, CodingKey {
        case periodNumber = "period_number"
        case startTime = "start_time"
        case endTime = "end_time"
    }
}
