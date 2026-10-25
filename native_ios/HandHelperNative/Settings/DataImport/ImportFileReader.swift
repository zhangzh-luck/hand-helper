import Foundation

enum ImportFileError: LocalizedError, Equatable {
    case wrongExtension
    case unreadable

    var errorDescription: String? {
        switch self {
        case .wrongExtension: "请选择 .xls 课表文件。"
        case .unreadable: "无法读取所选文件，请检查文件提供者或重新选择。"
        }
    }
}

@MainActor
protocol ImportFileReading {
    func readXLS(from url: URL) async throws -> MultipartFilePayload
}

@MainActor
struct ImportFileReader: ImportFileReading {
    func readXLS(from url: URL) async throws -> MultipartFilePayload {
        guard url.pathExtension.lowercased() == "xls" else { throw ImportFileError.wrongExtension }
        let task = Task.detached(priority: .userInitiated) {
            try Self.readBounded(url)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func readBounded(_ url: URL) throws -> MultipartFilePayload {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw ImportFileError.unreadable }
        defer { try? handle.close() }

        var data = Data()
        let inspectionLimit = MultipartFilePayload.maximumFileSize + 1
        do {
            while data.count < inspectionLimit {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: min(65_536, inspectionLimit - data.count)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ImportFileError.unreadable
        }
        return try MultipartFilePayload(data: data, fileExtension: .xls)
    }
}
