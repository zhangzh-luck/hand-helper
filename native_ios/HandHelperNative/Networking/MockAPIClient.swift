import Foundation

final class MockAPIClient: APIClientProtocol {
    var responseData: Data?
    var error: APIError?
    private(set) var requestedPaths: [String] = []

    func request<Value: Decodable>(
        _ method: String,
        path: String,
        body: Data?,
        preserveSessionOnPasswordError: Bool
    ) async throws -> Value {
        requestedPaths.append("\(method) \(path)")
        if let error { throw error }
        guard let responseData else { throw APIError.invalidResponse }
        let envelope = try JSONDecoder().decode(APIEnvelope<Value>.self, from: responseData)
        guard envelope.success else {
            throw APIError.server(status: 200, message: envelope.error?.message ?? "请求失败（HTTP 200）。")
        }
        if envelope.data == nil, Value.self == APIEmptyResponse.self {
            return APIEmptyResponse() as! Value
        }
        guard let value = envelope.data else { throw APIError.invalidData(status: 200) }
        return value
    }
}
