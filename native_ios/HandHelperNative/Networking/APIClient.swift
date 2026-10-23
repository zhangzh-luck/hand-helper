import Foundation

struct APIConfiguration {
    let baseURL: URL
    let timeout: TimeInterval

    static let development = APIConfiguration(
        baseURL: URL(string: "https://hand.zhangzh.cc")!,
        timeout: 20
    )
}

protocol APIClientProtocol {
    func request<Value: Decodable>(
        _ method: String,
        path: String,
        body: Data?,
        preserveSessionOnPasswordError: Bool
    ) async throws -> Value
}

final class APIClient: APIClientProtocol {
    private let configuration: APIConfiguration
    private let session: URLSession
    private let sessionStore: any SessionStore
    private let decoder = JSONDecoder()

    init(configuration: APIConfiguration, sessionStore: any SessionStore, session: URLSession? = nil) {
        self.configuration = configuration
        self.sessionStore = sessionStore
        if let session {
            self.session = session
        } else {
            let setup = URLSessionConfiguration.default
            setup.timeoutIntervalForRequest = configuration.timeout
            setup.httpShouldSetCookies = false
            self.session = URLSession(configuration: setup)
        }
    }

    func request<Value: Decodable>(
        _ method: String,
        path: String,
        body: Data? = nil,
        preserveSessionOnPasswordError: Bool = false
    ) async throws -> Value {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let scheme = configuration.baseURL.scheme, scheme == "https",
              let host = configuration.baseURL.host, !host.isEmpty,
              let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL,
              url.host == host else { throw APIError.invalidConfiguration }

        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if ["POST", "PUT", "PATCH", "DELETE"].contains(method) {
            let port = configuration.baseURL.port.map { ":\($0)" } ?? ""
            request.setValue("\(scheme)://\(host)\(port)", forHTTPHeaderField: "Origin")
        }
        if let cookie = sessionStore.cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw error.code == .timedOut ? APIError.timeout : APIError.connection
        } catch {
            throw APIError.connection
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if let raw = http.value(forHTTPHeaderField: "Set-Cookie"),
           let first = raw.split(separator: ";", maxSplits: 1).first,
           first.contains("=") {
            sessionStore.save(cookie: String(first))
        }

        let envelope: APIEnvelope<Value>
        do { envelope = try decoder.decode(APIEnvelope<Value>.self, from: data) }
        catch { throw APIError.invalidData(status: http.statusCode) }
        let serverMessage = envelope.error?.message
        if http.statusCode == 401 {
            if !(preserveSessionOnPasswordError && serverMessage == "当前密码错误") {
                sessionStore.clear()
            }
            throw APIError.unauthorized(message: serverMessage ?? "登录状态已失效")
        }
        guard (200..<300).contains(http.statusCode), envelope.success else {
            throw APIError.server(status: http.statusCode, message: serverMessage ?? "请求失败（HTTP \(http.statusCode)）。")
        }
        if envelope.data == nil, Value.self == APIEmptyResponse.self {
            return APIEmptyResponse() as! Value
        }
        guard let value = envelope.data else { throw APIError.invalidData(status: http.statusCode) }
        return value
    }
}
