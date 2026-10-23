import XCTest
@testable import HandHelperNative

final class AuthenticationTests: XCTestCase {
    func testLoginParsesCookieAndVerifiesIdentity() async throws {
        let client = makeClient { request in
            if request.url?.path == "/api/v1/auth/login" {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://hand.zhangzh.cc")
                let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                XCTAssertEqual(payload["username"], "student")
                XCTAssertEqual(payload["password"], "example-password")
                return self.response(request, 200, #"{"success":true,"data":{"authenticated":true,"username":"student"}}"#,
                                     cookie: "hand_helper_session=sample; Path=/; HttpOnly")
            }
            XCTAssertEqual(request.url?.path, "/api/v1/auth/me")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "hand_helper_session=sample")
            return self.response(request, 200, #"{"success":true,"data":{"authenticated":true,"username":"student"}}"#)
        }
        let result = try await client.login(username: "student", password: "example-password")
        XCTAssertEqual(result.cookie, "hand_helper_session=sample")
        XCTAssertEqual(result.identity.username, "student")
    }

    func testWrongPasswordAndMissingCookie() async {
        let wrong = makeClient { request in
            self.response(request, 401, #"{"success":false,"error":{"message":"用户名或密码错误"}}"#)
        }
        do { _ = try await wrong.login(username: "student", password: "wrong"); XCTFail("Expected 401") }
        catch let error as APIError { XCTAssertEqual(error, .unauthorized(message: "用户名或密码错误")) }
        catch { XCTFail("Unexpected error: \(error)") }

        let missing = makeClient { request in
            self.response(request, 200, #"{"success":true,"data":{"authenticated":true,"username":"student"}}"#)
        }
        do { _ = try await missing.login(username: "student", password: "example"); XCTFail("Expected missing cookie") }
        catch let error as APIError { XCTAssertEqual(error, .invalidResponse) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testVerifyUnauthorizedAndConnectionFailure() async {
        let unauthorized = makeClient { request in
            self.response(request, 401, #"{"success":false,"error":{"message":"登录状态已失效"}}"#)
        }
        do { _ = try await unauthorized.verify(cookie: "expired"); XCTFail("Expected 401") }
        catch let error as APIError { XCTAssertEqual(error, .unauthorized(message: "登录状态已失效")) }
        catch { XCTFail("Unexpected error: \(error)") }

        let connection = makeClient { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await connection.verify(cookie: "pending"); XCTFail("Expected connection error") }
        catch let error as APIError { XCTAssertEqual(error, .connection) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testRestoreLoginLogoutAndDuplicateSubmission() async {
        let session = TestSessionStore()
        session.save(cookie: "hand_helper_session=restored")
        let auth = TestAuthenticationClient()
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth)
        await state.restoreSession()
        XCTAssertEqual(state.authenticationStatus, .signedIn("student"))
        XCTAssertTrue(state.isAuthenticated)
        let restoredRevision = state.authenticationRevision
        XCTAssertEqual(try? state.requireCurrentAccount(revision: restoredRevision), "user:student")

        auth.loginWait = true
        let first = Task { await state.login(username: "new", password: "example") }
        await auth.waitForLoginStart()
        XCTAssertTrue(state.isLoginSubmitting)
        await state.login(username: "new", password: "example")
        XCTAssertEqual(auth.loginCount, 1)
        auth.resumeLogin()
        await first.value
        XCTAssertEqual(session.cookie, "hand_helper_session=new")
        XCTAssertEqual(state.authenticationStatus, .signedIn("new"))
        XCTAssertThrowsError(try state.requireCurrentAccount(revision: restoredRevision))
        let newRevision = state.authenticationRevision
        XCTAssertEqual(try? state.requireCurrentAccount(revision: newRevision), "user:new")

        await state.logout()
        XCTAssertNil(session.cookie)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.authenticationStatus, .signedOut)
        XCTAssertThrowsError(try state.requireCurrentAccount(revision: newRevision))
        XCTAssertEqual(auth.logoutCount, 1)
    }

    @MainActor
    func testRestoreUnauthorizedAndOfflineHaveDifferentOutcomes() async {
        let expiredSession = TestSessionStore()
        expiredSession.save(cookie: "expired")
        let expiredAuth = TestAuthenticationClient()
        expiredAuth.verifyError = APIError.unauthorized(message: "登录状态已失效")
        let expired = AppState(api: MockAPIClient(), sessionStore: expiredSession, authentication: expiredAuth)
        await expired.restoreSession()
        XCTAssertNil(expiredSession.cookie)
        XCTAssertEqual(expired.authenticationStatus, .expired)
        XCTAssertNil(expired.verifiedAccount.owner)

        let offlineSession = TestSessionStore()
        offlineSession.save(cookie: "pending")
        let offlineAuth = TestAuthenticationClient()
        offlineAuth.verifyError = APIError.connection
        let offline = AppState(api: MockAPIClient(), sessionStore: offlineSession, authentication: offlineAuth)
        await offline.restoreSession()
        XCTAssertEqual(offlineSession.cookie, "pending")
        XCTAssertFalse(offline.isAuthenticated)
        XCTAssertEqual(offline.authenticationStatus, .offline)
        XCTAssertThrowsError(try offline.verifiedAccount.requireOwner(cookie: "pending"))
    }

    @MainActor
    func testOldLoginResultCannotRestoreLoggedOutIdentity() async {
        let session = TestSessionStore()
        let auth = TestAuthenticationClient()
        auth.loginWait = true
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth)
        let pending = Task { await state.login(username: "new", password: "example") }
        await auth.waitForLoginStart()
        await state.logout()
        auth.resumeLogin()
        await pending.value
        XCTAssertNil(session.cookie)
        XCTAssertEqual(state.authenticationStatus, .signedOut)
    }

    @MainActor
    func testFailedLoginKeepsExistingVerifiedSession() async {
        let session = TestSessionStore()
        session.save(cookie: "hand_helper_session=old")
        let auth = TestAuthenticationClient()
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth)
        await state.restoreSession()
        auth.loginError = APIError.unauthorized(message: "用户名或密码错误")
        await state.login(username: "other", password: "wrong")
        XCTAssertEqual(session.cookie, "hand_helper_session=old")
        XCTAssertEqual(state.authenticationStatus, .signedIn("student"))
        XCTAssertEqual(state.loginError, "用户名或密码错误")
    }

    @MainActor
    func testUnauthorizedImmediatelyRevokesScheduleWrites() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = TestSessionStore()
        session.save(cookie: "hand_helper_session=alice")
        let state = AppState(api: MockAPIClient(), sessionStore: session,
                             authentication: TestAuthenticationClient())
        await state.restoreSession()
        let store = LocalScheduleStore(session: session, account: state.verifiedAccount, directory: folder)
        try store.save(CustomSchedule(id: 0, title: "已验证安排", date: "2026-10-23", time: "09:00"))
        state.handleUnauthorized()
        XCTAssertNil(session.cookie)
        XCTAssertNil(state.verifiedAccount.owner)
        XCTAssertThrowsError(try store.all())
        XCTAssertThrowsError(try store.save(CustomSchedule(id: 0, title: "禁止写入", date: "2026-10-23", time: "10:00")))
    }

    @MainActor
    func testTodayRefreshLogoutAccountIsolationAndStaleResponse() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = TestSessionStore()
        let repository = AuthenticationCourseRepository(session: session)
        let course = try JSONDecoder().decode(CourseSession.self, from: Data(#"{"id":1,"course_name":"测试课程","session_date":"2026-10-23","start_datetime":"2026-10-23T08:00:00Z","end_datetime":"2026-10-23T09:00:00Z"}"#.utf8))
        var alice = CourseSnapshot.empty
        alice.calendarSessions = [course]
        alice.lastRefreshDate = "2026-10-23"
        repository.snapshots["alice"] = alice
        repository.snapshots["bob"] = .empty
        let model = TodayViewModel(repository: repository, wallpaperStore: WallpaperStore(session: session, directory: folder))

        model.authenticationDidChange(allowPrivateCache: false)
        XCTAssertNil(model.snapshot)
        session.save(cookie: "alice")
        model.authenticationDidChange(allowPrivateCache: true)
        XCTAssertEqual(model.snapshot?.calendarSessions.count, 1)
        repository.waitForRefresh = true
        let oldRequest = Task { await model.refresh() }
        await repository.waitForRefreshStart()
        session.save(cookie: "bob")
        model.authenticationDidChange(allowPrivateCache: true)
        repository.resumeRefresh()
        await oldRequest.value
        XCTAssertTrue(model.snapshot?.calendarSessions.isEmpty == true)

        session.clear()
        model.authenticationDidChange(allowPrivateCache: false)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.courses.isEmpty)
    }

    @MainActor
    func testLoginThenRealTimetableEnvelopeRefreshesToday() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = TestSessionStore()
        let auth = TestAuthenticationClient()
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth)
        let api = AuthenticationRoutingAPIClient()
        let localStore = LocalScheduleStore(session: session, account: state.verifiedAccount, directory: folder)
        let repository = DiskCourseRepository(api: api, session: session, account: state.verifiedAccount,
                                              directory: folder, localStore: localStore)
        let model = TodayViewModel(repository: repository, wallpaperStore: WallpaperStore(session: session, directory: folder))

        model.load(allowPrivateCache: false)
        XCTAssertNil(model.snapshot)
        await state.login(username: "student", password: "example")
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.authenticationRevision, 1)
        model.authenticationDidChange(allowPrivateCache: state.isAuthenticated)
        let unauthorized = await model.refresh()
        XCTAssertFalse(unauthorized)
        XCTAssertEqual(model.snapshot?.calendarSessions.first?.name, "测试课程")
        XCTAssertEqual(model.snapshot?.calendarSessions.first?.room, "A101")
        XCTAssertTrue(api.requestedPaths.contains("GET /api/v1/timetable"))

        await state.logout()
        model.authenticationDidChange(allowPrivateCache: state.isAuthenticated)
        XCTAssertNil(model.snapshot)
    }

    private func makeClient(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> AuthenticationClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthenticationURLProtocol.self]
        AuthenticationURLProtocol.handler = handler
        return AuthenticationClient(session: URLSession(configuration: configuration))
    }

    private func response(_ request: URLRequest, _ status: Int, _ json: String,
                          cookie: String? = nil) -> (HTTPURLResponse, Data) {
        let headers = cookie.map { ["Set-Cookie": $0] }
        return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, Data(json.utf8))
    }
}

private final class AuthenticationURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class TestSessionStore: SessionStore {
    private(set) var cookie: String?
    func save(cookie: String) { self.cookie = cookie }
    func clear() { cookie = nil }
}

private final class AuthenticationRoutingAPIClient: APIClientProtocol {
    private(set) var requestedPaths: [String] = []
    func request<Value: Decodable>(_ method: String, path: String, body: Data?,
                                   preserveSessionOnPasswordError: Bool) async throws -> Value {
        requestedPaths.append("\(method) \(path)")
        let json: String
        switch path {
        case "/api/v1/auth/me": json = #"{"success":true,"data":{"authenticated":true,"username":"student"}}"#
        case "/api/v1/timetable":
            json = #"{"success":true,"data":[{"id":1,"course_name":"测试课程","session_date":"2026-10-23","start_datetime":"2026-10-23T08:00:00Z","end_datetime":"2026-10-23T09:00:00Z","classroom":"A101"}]}"#
        default: json = #"{"success":true,"data":[]}"#
        }
        let envelope = try JSONDecoder().decode(APIEnvelope<Value>.self, from: Data(json.utf8))
        return try XCTUnwrap(envelope.data)
    }
}

@MainActor
private final class AuthenticationCourseRepository: CourseRepository {
    let session: TestSessionStore
    var snapshots: [String: CourseSnapshot] = [:]
    var waitForRefresh = false
    private var continuation: CheckedContinuation<Void, Never>?
    var sessionCookie: String? { session.cookie }
    var canEditSchedules: Bool { session.cookie != nil }
    init(session: TestSessionStore) { self.session = session }
    func cached() throws -> CourseSnapshot? {
        guard let cookie = session.cookie else { return nil }
        return snapshots[cookie]
    }
    func refresh(on date: Date) async throws -> CourseSnapshot {
        let original = session.cookie
        if waitForRefresh { await withCheckedContinuation { continuation = $0 } }
        return snapshots[original ?? ""] ?? .empty
    }
    func localSchedules(on date: Date) throws -> [CustomSchedule] { [] }
    func allLocalSchedules() throws -> [CustomSchedule] { [] }
    func saveSchedule(_ schedule: CustomSchedule) throws {}
    func deleteSchedule(id: Int) throws {}
    func saveManualRule(_ rule: ManualCourseRule) throws {}
    func saveProfile(_ profile: TodayProfile) throws {}
    func resumeRefresh() { continuation?.resume(); continuation = nil }
    func waitForRefreshStart() async {
        for _ in 0..<1_000 {
            if continuation != nil { return }
            await Task.yield()
        }
        XCTFail("Refresh did not begin")
    }
}

@MainActor
private final class TestAuthenticationClient: AuthenticationClientProtocol {
    var verifyError: Error?
    var loginError: Error?
    var loginWait = false
    var loginCount = 0
    var logoutCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func login(username: String, password: String) async throws -> (cookie: String, identity: VerifiedIdentity) {
        loginCount += 1
        if loginWait { await withCheckedContinuation { continuation = $0 } }
        if let loginError { throw loginError }
        return ("hand_helper_session=new", VerifiedIdentity(authenticated: true, username: username))
    }
    func verify(cookie: String) async throws -> VerifiedIdentity {
        if let verifyError { throw verifyError }
        return VerifiedIdentity(authenticated: true, username: "student")
    }
    func logout(cookie: String) async throws { logoutCount += 1 }
    func resumeLogin() { continuation?.resume(); continuation = nil }
    func waitForLoginStart() async {
        for _ in 0..<1_000 {
            if loginCount > 0 && continuation != nil { return }
            await Task.yield()
        }
        XCTFail("Login did not begin")
    }
}
