import Foundation

enum APIError: Error, Equatable {
    case invalidConfiguration
    case invalidResponse
    case invalidData(status: Int)
    case timeout
    case connection
    case unauthorized(message: String)
    case server(status: Int, message: String)

    var message: String {
        switch self {
        case .invalidConfiguration: "API 地址配置无效。"
        case .invalidResponse, .invalidData: "服务器返回的数据格式异常。"
        case .timeout: "请求超时，请检查网络后重试。"
        case .connection: "无法连接服务器，请检查网络后重试。"
        case .unauthorized(let message), .server(_, let message): message
        }
    }
}
