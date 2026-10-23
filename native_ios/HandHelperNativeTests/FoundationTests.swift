import XCTest
@testable import HandHelperNative

final class FoundationTests: XCTestCase {
    func testEnvelopeAndRealFieldNamesDecode() throws {
        let json = #"{"success":true,"data":{"id":8,"source_term_id":"2026-fall","display_name":"秋季","start_date":null,"is_current":true}}"#.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(APIEnvelope<TermInfo>.self, from: json)
        XCTAssertTrue(envelope.success)
        XCTAssertEqual(envelope.data?.sourceTermID, "2026-fall")
        XCTAssertEqual(envelope.data?.isCurrent, true)
    }

    func testErrorMappingAndUnauthorizedClearsSession() async throws {
        let store = MemorySessionStore()
        store.save(cookie: "session=test")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(configuration: .development, sessionStore: store, session: session)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=test")
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, #"{"success":false,"error":{"message":"登录状态已失效"}}"#.data(using: .utf8)!)
        }
        do {
            let _: AuthIdentity = try await client.request("GET", path: "/api/v1/auth/me")
            XCTFail("Expected unauthorized")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized(message: "登录状态已失效"))
        }
        XCTAssertNil(store.cookie)
        XCTAssertEqual(APIError.timeout.message, "请求超时，请检查网络后重试。")
        XCTAssertEqual(APIError.server(status: 500, message: "失败").message, "失败")
    }

    @MainActor
    func testAppearancePersistsAndSwitches() {
        let suite = "appearance-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(api: MockAPIClient(), sessionStore: MemorySessionStore(), preferences: defaults)
        XCTAssertEqual(state.appearance, .system)
        state.setAppearance(.dark)
        XCTAssertEqual(state.appearance.colorScheme, .dark)
        XCTAssertEqual(AppState(api: MockAPIClient(), sessionStore: MemorySessionStore(), preferences: defaults).appearance, .dark)
        state.setAppearance(.light)
        XCTAssertEqual(state.appearance.colorScheme, .light)
    }

    func testSessionStoreContract() {
        let store: any SessionStore = MemorySessionStore()
        XCTAssertNil(store.cookie)
        store.save(cookie: "session=test")
        XCTAssertEqual(store.cookie, "session=test")
        store.clear()
        XCTAssertNil(store.cookie)
    }

    func testMockRequestDecodesAndRecords() async throws {
        let mock = MockAPIClient()
        mock.responseData = #"{"success":true,"data":{"username":"tester"}}"#.data(using: .utf8)
        let user: AuthIdentity = try await mock.request("GET", path: "/api/v1/auth/me", body: nil, preserveSessionOnPasswordError: false)
        XCTAssertEqual(user.username, "tester")
        XCTAssertEqual(mock.requestedPaths, ["GET /api/v1/auth/me"])
        mock.responseData = #"{"success":true,"data":null}"#.data(using: .utf8)
        let empty: APIEmptyResponse = try await mock.request("POST", path: "/api/v1/auth/logout", body: nil, preserveSessionOnPasswordError: false)
        XCTAssertEqual(empty, APIEmptyResponse())
    }

    func testURLSessionRequestSendsOriginAndStoresCookie() async throws {
        let store = MemorySessionStore()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = APIClient(
            configuration: .development,
            sessionStore: store,
            session: URLSession(configuration: configuration)
        )
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://hand.zhangzh.cc")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Set-Cookie": "session=new-value; Path=/; HttpOnly"]
            )!
            return (response, #"{"success":true,"data":{"username":"tester"}}"#.data(using: .utf8)!)
        }
        let user: AuthIdentity = try await client.request(
            "POST", path: "/api/v1/auth/passkey/verify", body: #"{}"#.data(using: .utf8)
        )
        XCTAssertEqual(user.username, "tester")
        XCTAssertEqual(store.cookie, "session=new-value")
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { XCTFail("Missing URLProtocol handler"); return }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class MemorySessionStore: SessionStore {
    private(set) var cookie: String?
    func save(cookie: String) { self.cookie = cookie }
    func clear() { cookie = nil }
}
