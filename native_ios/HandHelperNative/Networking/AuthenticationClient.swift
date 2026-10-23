import Foundation

struct VerifiedIdentity: Decodable, Equatable {
    let authenticated: Bool
    let username: String
}

private struct LoginResponse: Decodable {
    let authenticated: Bool
    let username: String
}

struct LoginCredentials: Encodable {
    let username: String
    let password: String
}

protocol AuthenticationClientProtocol {
    func login(username: String, password: String) async throws -> (cookie: String, identity: VerifiedIdentity)
    func verify(cookie: String) async throws -> VerifiedIdentity
    func verifySession(cookie: String) async throws -> (cookie: String, identity: VerifiedIdentity)
    func logout(cookie: String) async throws
}

extension AuthenticationClientProtocol {
    func verifySession(cookie: String) async throws -> (cookie: String, identity: VerifiedIdentity) {
        let identity = try await verify(cookie: cookie)
        return (cookie, identity)
    }
}

final class AuthenticationClient: AuthenticationClientProtocol {
    private let configuration: APIConfiguration
    private let session: URLSession

    init(configuration: APIConfiguration = .development, session: URLSession? = nil) {
        self.configuration = configuration
        if let session { self.session = session }
        else {
            let options = URLSessionConfiguration.ephemeral
            options.httpShouldSetCookies = false
            options.timeoutIntervalForRequest = configuration.timeout
            self.session = URLSession(configuration: options)
        }
    }

    func login(username: String, password: String) async throws -> (cookie: String, identity: VerifiedIdentity) {
        let body = try JSONEncoder().encode(LoginCredentials(username: username, password: password))
        let (response, identity): (HTTPURLResponse, LoginResponse) = try await send("POST", path: "/api/v1/auth/login", body: body)
        guard identity.authenticated,
              let cookie = Self.responseCookie(response) else { throw APIError.invalidResponse }
        let confirmed = try await verifySession(cookie: cookie)
        guard confirmed.identity.authenticated,
              confirmed.identity.username == identity.username else { throw APIError.invalidResponse }
        return confirmed
    }

    func verify(cookie: String) async throws -> VerifiedIdentity {
        let result = try await verifySession(cookie: cookie)
        return result.identity
    }

    func verifySession(cookie: String) async throws -> (cookie: String, identity: VerifiedIdentity) {
        let (response, identity): (HTTPURLResponse, VerifiedIdentity) = try await send("GET", path: "/api/v1/auth/me", cookie: cookie)
        guard identity.authenticated, !identity.username.isEmpty else { throw APIError.invalidResponse }
        if let header = response.value(forHTTPHeaderField: "Set-Cookie"),
           let first = header.split(separator: ";", maxSplits: 1).first,
           let equal = first.firstIndex(of: "="),
           cookie.hasPrefix(String(first[..<equal]) + "=") {
            guard let replacement = Self.responseCookie(response) else { throw APIError.invalidResponse }
            return (replacement, identity)
        }
        return (cookie, identity)
    }

    private static func responseCookie(_ response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Set-Cookie"),
              let first = header.split(separator: ";", maxSplits: 1).first,
              let equal = first.firstIndex(of: "="), equal != first.startIndex,
              !first[first.index(after: equal)...].isEmpty else { return nil }
        return String(first)
    }

    func logout(cookie: String) async throws {
        let (_, value): (HTTPURLResponse, LogoutResponse) = try await send("POST", path: "/api/v1/auth/logout", cookie: cookie)
        guard value.loggedOut else { throw APIError.invalidResponse }
    }

    private func send<Value: Decodable>(_ method: String, path: String, cookie: String? = nil,
                                        body: Data? = nil) async throws -> (HTTPURLResponse, Value) {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL,
              url.host == configuration.baseURL.host,
              configuration.baseURL.scheme == "https" else { throw APIError.invalidConfiguration }
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            guard let scheme = configuration.baseURL.scheme, let host = configuration.baseURL.host else {
                throw APIError.invalidConfiguration
            }
            let port = configuration.baseURL.port.map { ":\($0)" } ?? ""
            request.setValue("\(scheme)://\(host)\(port)", forHTTPHeaderField: "Origin")
        }
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let raw: URLResponse
        do { (data, raw) = try await session.data(for: request) }
        catch let error as URLError { throw error.code == .timedOut ? APIError.timeout : APIError.connection }
        catch { throw APIError.connection }
        guard let response = raw as? HTTPURLResponse else { throw APIError.invalidResponse }
        if response.statusCode == 401 {
            let error = try? JSONDecoder().decode(APIEnvelope<APIEmptyResponse>.self, from: data)
            throw APIError.unauthorized(message: error?.error?.message ?? "登录状态已失效，请重新登录")
        }
        let envelope: APIEnvelope<Value>
        do { envelope = try JSONDecoder().decode(APIEnvelope<Value>.self, from: data) }
        catch { throw APIError.invalidData(status: response.statusCode) }
        let message = envelope.error?.message ?? "请求失败（HTTP \(response.statusCode)）。"
        guard (200..<300).contains(response.statusCode), envelope.success else {
            throw APIError.server(status: response.statusCode, message: message)
        }
        guard let value = envelope.data else { throw APIError.invalidData(status: response.statusCode) }
        return (response, value)
    }
}

private struct LogoutResponse: Decodable {
    let loggedOut: Bool
    enum CodingKeys: String, CodingKey { case loggedOut = "logged_out" }
}
