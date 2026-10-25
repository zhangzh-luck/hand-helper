import Foundation

@MainActor
protocol TimetableImportServicing {
    func upload(_ file: MultipartFilePayload) async throws -> TimetableImportResult
    func inspect(isCurrent: @escaping @MainActor () -> Bool) async throws -> TimetableImportInspection
}

@MainActor
struct TimetableImportService: TimetableImportServicing {
    let api: any APIClientProtocol

    func upload(_ file: MultipartFilePayload) async throws -> TimetableImportResult {
        try await api.uploadMultipart(path: "/api/v1/timetable/import-file", file: file, termID: nil)
    }

    func inspect(isCurrent: @escaping @MainActor () -> Bool) async throws -> TimetableImportInspection {
        guard isCurrent(), !Task.isCancelled else { throw MultipartUploadError.sessionChanged }
        let terms: [TermInfo] = try await api.request("GET", path: "/api/v1/terms", body: nil,
                                                      preserveSessionOnPasswordError: false)
        guard isCurrent(), !Task.isCancelled else { throw MultipartUploadError.sessionChanged }
        let sessions: [CourseSession] = try await api.request("GET", path: "/api/v1/timetable", body: nil,
                                                              preserveSessionOnPasswordError: false)
        guard isCurrent(), !Task.isCancelled else { throw MultipartUploadError.sessionChanged }
        return TimetableImportInspection(termCount: terms.count, sessionCount: sessions.count)
    }
}
