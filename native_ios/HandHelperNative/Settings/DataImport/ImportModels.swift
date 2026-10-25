import Foundation

struct TimetableImportResult: Decodable, Equatable {
    let termID: String
    let coursesImported: Int
    let sessionsGenerated: Int
    let ignoredNotes: Bool

    enum CodingKeys: String, CodingKey {
        case termID = "term_id"
        case coursesImported = "courses_imported"
        case sessionsGenerated = "sessions_generated"
        case ignoredNotes = "ignored_notes"
    }
}

struct TimetableImportInspection: Equatable {
    let termCount: Int
    let sessionCount: Int
}

struct PendingTimetableImport: Identifiable, Equatable {
    enum Phase: Equatable {
        case uploading
        case accepted(TimetableImportResult)
        case refreshPending(TimetableImportResult, sequence: Int)
        case refreshCompleted(TimetableImportResult)
        case unconfirmed(String)
    }

    let id: UUID
    let owner: String
    var phase: Phase
    var inspection: TimetableImportInspection?
}
