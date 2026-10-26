import Foundation

@MainActor
protocol GradeImportServicing {
    func preview(file: MultipartFilePayload, termID: String?) async throws -> GradeImportPreview
}

@MainActor
struct GradeImportService: GradeImportServicing {
    let api: any APIClientProtocol

    func preview(file: MultipartFilePayload, termID: String?) async throws -> GradeImportPreview {
        try await api.uploadMultipart(path: "/api/v1/grades/import-file", file: file, termID: termID)
    }
}
