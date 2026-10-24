import Foundation

enum MultipartUploadError: LocalizedError, Equatable {
    case emptyFile
    case fileTooLarge
    case invalidTermID
    case sessionChanged

    var errorDescription: String? {
        switch self {
        case .emptyFile: "请选择非空文件。"
        case .fileTooLarge: "文件不能超过 2 MB。"
        case .invalidTermID: "学期标识格式无效。"
        case .sessionChanged: "登录状态已变化，上传结果需要核实。"
        }
    }
}

enum MultipartFileExtension: String {
    case xls
    case html
    case htm

    var mimeType: String {
        switch self {
        case .xls: "application/vnd.ms-excel"
        case .html, .htm: "text/html"
        }
    }
}

struct MultipartFilePayload {
    static let maximumFileSize = 2_000_000

    let data: Data
    let fileExtension: MultipartFileExtension

    // The server only needs the extension. Never put a file-provider supplied name in a header.
    var safeFileName: String { "upload.\(fileExtension.rawValue)" }
    var mimeType: String { fileExtension.mimeType }

    init(data: Data, fileExtension: MultipartFileExtension) throws {
        guard !data.isEmpty else { throw MultipartUploadError.emptyFile }
        guard data.count <= Self.maximumFileSize else { throw MultipartUploadError.fileTooLarge }
        self.data = data
        self.fileExtension = fileExtension
    }

    func body(boundary: String) -> Data {
        var result = Data()
        result.append(Data("--\(boundary)\r\n".utf8))
        result.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFileName)\"\r\n".utf8))
        result.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        result.append(data)
        result.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return result
    }
}
