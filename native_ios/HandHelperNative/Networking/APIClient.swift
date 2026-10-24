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

    func uploadMultipart<Value: Decodable>(
        path: String,
        file: MultipartFilePayload,
        termID: String?
    ) async throws -> Value
}

extension APIClientProtocol {
    // Existing JSON-only test doubles remain valid. Upload tests supply an explicit mock.
    func uploadMultipart<Value: Decodable>(
        path: String,
        file: MultipartFilePayload,
        termID: String? = nil
    ) async throws -> Value {
        throw APIError.invalidConfiguration
    }
}

enum APISessionEvent {
    case rotated(previous: String, current: String)
    case unauthorized(previous: String)
}

final class APIClient: APIClientProtocol {
    private let configuration: APIConfiguration
    private let session: URLSession
    private let sessionStore: any SessionStore
    private let decoder = JSONDecoder()
    var onSessionEvent: ((APISessionEvent) -> Void)?
    private let epochLock = NSLock()
    private var sessionEpoch = 0

    func invalidatePendingSessionRequests() {
        epochLock.lock()
        sessionEpoch += 1
        epochLock.unlock()
    }

    private func currentEpoch() -> Int {
        epochLock.lock()
        defer { epochLock.unlock() }
        return sessionEpoch
    }

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
        let url = try validatedURL(path: path)
        guard let scheme = configuration.baseURL.scheme,
              let host = configuration.baseURL.host else { throw APIError.invalidConfiguration }

        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if ["POST", "PUT", "PATCH", "DELETE"].contains(method) {
            let port = configuration.baseURL.port.map { ":\($0)" } ?? ""
            request.setValue("\(scheme)://\(host)\(port)", forHTTPHeaderField: "Origin")
        }
        let requestEpoch = currentEpoch()
        let requestCookie = sessionStore.cookie
        guard currentEpoch() == requestEpoch else {
            throw APIError.unauthorized(message: "登录状态已变化")
        }
        if let requestCookie { request.setValue(requestCookie, forHTTPHeaderField: "Cookie") }
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
        return try decodeResponse(data, response: response, requestEpoch: requestEpoch,
                                  requestCookie: requestCookie,
                                  preserveSessionOnPasswordError: preserveSessionOnPasswordError)
    }

    func uploadMultipart<Value: Decodable>(
        path: String,
        file: MultipartFilePayload,
        termID: String? = nil
    ) async throws -> Value {
        // Recheck even when a caller somehow supplies a payload outside its initializer.
        guard !file.data.isEmpty else { throw MultipartUploadError.emptyFile }
        guard file.data.count <= MultipartFilePayload.maximumFileSize else {
            throw MultipartUploadError.fileTooLarge
        }
        try Task.checkCancellation()

        var url = try validatedURL(path: path)
        if let termID {
            guard termID.range(of: #"^20\d{2}-20\d{2}-[12]$"#,
                               options: .regularExpression) != nil else {
                throw MultipartUploadError.invalidTermID
            }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.queryItems == nil else { throw APIError.invalidConfiguration }
            components.queryItems = [URLQueryItem(name: "term_id", value: termID)]
            guard let encodedURL = components.url else { throw APIError.invalidConfiguration }
            url = encodedURL
        }

        var boundary = "HandHelper-\(UUID().uuidString)"
        while file.data.range(of: Data(boundary.utf8)) != nil {
            boundary = "HandHelper-\(UUID().uuidString)"
        }
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        guard let scheme = configuration.baseURL.scheme,
              let host = configuration.baseURL.host else { throw APIError.invalidConfiguration }
        let port = configuration.baseURL.port.map { ":\($0)" } ?? ""
        request.setValue("\(scheme)://\(host)\(port)", forHTTPHeaderField: "Origin")

        let requestEpoch = currentEpoch()
        let requestCookie = sessionStore.cookie
        guard currentEpoch() == requestEpoch else { throw MultipartUploadError.sessionChanged }
        if let requestCookie { request.setValue(requestCookie, forHTTPHeaderField: "Cookie") }
        request.httpBody = file.body(boundary: boundary)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw error.code == .timedOut ? APIError.timeout : APIError.connection
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw APIError.connection
        }
        try Task.checkCancellation()
        guard currentEpoch() == requestEpoch, sessionStore.cookie == requestCookie else {
            throw MultipartUploadError.sessionChanged
        }
        return try decodeResponse(data, response: response, requestEpoch: requestEpoch,
                                  requestCookie: requestCookie,
                                  preserveSessionOnPasswordError: false)
    }

    private func validatedURL(path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              configuration.baseURL.scheme == "https",
              let host = configuration.baseURL.host, !host.isEmpty,
              let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL,
              url.host == host else { throw APIError.invalidConfiguration }
        return url
    }

    private func decodeResponse<Value: Decodable>(
        _ data: Data,
        response: URLResponse,
        requestEpoch: Int,
        requestCookie: String?,
        preserveSessionOnPasswordError: Bool
    ) throws -> Value {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 {
            let error = try? decoder.decode(APIEnvelope<APIEmptyResponse>.self, from: data)
            let message = error?.error?.message ?? "登录状态已失效，请重新登录"
            if currentEpoch() == requestEpoch, sessionStore.cookie == requestCookie,
                !(preserveSessionOnPasswordError && message == "当前密码错误") {
                sessionStore.clear()
                if let requestCookie { onSessionEvent?(.unauthorized(previous: requestCookie)) }
            }
            throw APIError.unauthorized(message: message)
        }
        let envelope: APIEnvelope<Value>
        do { envelope = try decoder.decode(APIEnvelope<Value>.self, from: data) }
        catch { throw APIError.invalidData(status: http.statusCode) }
        let serverMessage = envelope.error?.message
        guard (200..<300).contains(http.statusCode), envelope.success else {
            throw APIError.server(status: http.statusCode, message: serverMessage ?? "请求失败（HTTP \(http.statusCode)）。")
        }
        if currentEpoch() == requestEpoch, sessionStore.cookie == requestCookie,
           let raw = http.value(forHTTPHeaderField: "Set-Cookie"),
           let first = raw.split(separator: ";", maxSplits: 1).first,
           let equal = first.firstIndex(of: "="),
           let requestCookie,
           requestCookie.hasPrefix(String(first[..<equal]) + "=") {
            let replacement = String(first)
            sessionStore.save(cookie: replacement)
            guard sessionStore.cookie == replacement else {
                sessionStore.clear()
                onSessionEvent?(.unauthorized(previous: requestCookie))
                throw APIError.unauthorized(message: "无法保存更新后的登录状态")
            }
            if replacement != requestCookie {
                onSessionEvent?(.rotated(previous: requestCookie, current: replacement))
            }
        }
        if envelope.data == nil, Value.self == APIEmptyResponse.self {
            return APIEmptyResponse() as! Value
        }
        guard let value = envelope.data else { throw APIError.invalidData(status: http.statusCode) }
        return value
    }
}
