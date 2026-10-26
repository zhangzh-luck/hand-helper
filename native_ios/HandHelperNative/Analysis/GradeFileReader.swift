import Foundation

enum GradeFileError: LocalizedError, Equatable {
    case wrongExtension
    case unreadable

    var errorDescription: String? {
        switch self {
        case .wrongExtension: "请选择 .xls、.html 或 .htm 成绩文件。"
        case .unreadable: "无法读取所选文件，请检查文件提供者或重新选择。"
        }
    }
}

@MainActor
protocol GradeFileReading {
    func read(from url: URL) async throws -> MultipartFilePayload
}

@MainActor
struct GradeFileReader: GradeFileReading {
    func read(from url: URL) async throws -> MultipartFilePayload {
        guard let ext = MultipartFileExtension(rawValue: url.pathExtension.lowercased()) else {
            throw GradeFileError.wrongExtension
        }
        let task = Task.detached(priority: .userInitiated) {
            try Self.readBounded(url, fileExtension: ext)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func readBounded(_ url: URL, fileExtension: MultipartFileExtension) throws -> MultipartFilePayload {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw GradeFileError.unreadable }
        defer { try? handle.close() }

        var data = Data()
        let limit = MultipartFilePayload.maximumFileSize + 1
        do {
            while data.count < limit {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: min(65_536, limit - data.count)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GradeFileError.unreadable
        }
        try Task.checkCancellation()
        return try MultipartFilePayload(data: data, fileExtension: fileExtension)
    }
}
