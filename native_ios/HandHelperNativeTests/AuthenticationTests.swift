import XCTest
@testable import HandHelperNative

final class AuthenticationTests: XCTestCase {
    func testLoginRequestBodyReaderSupportsDataAndStream() throws {
        let url = try XCTUnwrap(URL(string: "https://hand.zhangzh.cc/api/v1/auth/login"))
        let json = Data(#"{"username":"student","password":"example-password"}"#.utf8)

        var dataRequest = URLRequest(url: url)
        dataRequest.httpBody = json
        XCTAssertEqual(try requestBody(dataRequest), json)

        var streamedRequest = URLRequest(url: url)
        streamedRequest.httpBodyStream = InputStream(data: json)
        XCTAssertEqual(try requestBody(streamedRequest), json)
    }

    func testLoginParsesCookieAndVerifiesIdentity() async throws {
        let client = makeClient { request in
            if request.url?.path == "/api/v1/auth/login" {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://hand.zhangzh.cc")
                let body = try self.requestBody(request)
                let payload = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: String],
                    "Login request body must be a JSON object with string fields"
                )
                XCTAssertEqual(payload["username"], "student")
                XCTAssertEqual(payload["password"], "example-password")
                return try self.response(request, 200, #"{"success":true,"data":{"authenticated":true,"username":"student"}}"#,
                                     cookie: "hand_helper_session=sample; Path=/; HttpOnly")
            }
            XCTAssertEqual(request.url?.path, "/api/v1/auth/me")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "hand_helper_session=sample")
            return try self.response(request, 200, #"{"success":true,"data":{"authenticated":true,"username":"student"}}"#)
        }
        let result = try await client.login(username: "student", password: "example-password")
        XCTAssertEqual(result.cookie, "hand_helper_session=sample")
        XCTAssertEqual(result.identity.username, "student")
    }

    func testAuthMeReturnsRotatedCookieWithVerifiedIdentity() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/me")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=old")
            return try self.response(request, 200,
                #"{"success":true,"data":{"authenticated":true,"username":"student"}}"#,
                cookie: "session=rotated; Path=/; HttpOnly")
        }
        let result = try await client.verifySession(cookie: "session=old")
        XCTAssertEqual(result.cookie, "session=rotated")
        XCTAssertEqual(result.identity.username, "student")
    }

    func testWrongPasswordAndMissingCookie() async {
        let wrong = makeClient { request in
            try self.response(request, 401, #"{"success":false,"error":{"message":"用户名或密码错误"}}"#)
        }
        do { _ = try await wrong.login(username: "student", password: "wrong"); XCTFail("Expected 401") }
        catch let error as APIError { XCTAssertEqual(error, .unauthorized(message: "用户名或密码错误")) }
        catch { XCTFail("Unexpected error: \(error)") }

        let missing = makeClient { request in
            try self.response(request, 200, #"{"success":true,"data":{"authenticated":true,"username":"student"}}"#)
        }
        do { _ = try await missing.login(username: "student", password: "example"); XCTFail("Expected missing cookie") }
        catch let error as APIError { XCTAssertEqual(error, .invalidResponse) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testVerifyUnauthorizedAndConnectionFailure() async {
        let unauthorized = makeClient { request in
            try self.response(request, 401, #"{"success":false,"error":{"message":"登录状态已失效"}}"#)
        }
        do { _ = try await unauthorized.verify(cookie: "expired"); XCTFail("Expected 401") }
        catch let error as APIError { XCTAssertEqual(error, .unauthorized(message: "登录状态已失效")) }
        catch { XCTFail("Unexpected error: \(error)") }

        let connection = makeClient { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await connection.verify(cookie: "pending"); XCTFail("Expected connection error") }
        catch let error as APIError { XCTAssertEqual(error, .connection) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testAuthMeNonJSONUnauthorizedIsNotConnectionFailure() async {
        let client = makeClient { request in
            try self.response(request, 401, "not JSON")
        }
        do {
            _ = try await client.verify(cookie: "session=expired")
            XCTFail("Expected unauthorized")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized(message: "登录状态已失效，请重新登录"))
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testRestoreLoginLogoutAndDuplicateSubmission() async {
        let session = TestSessionStore()
        session.save(cookie: "hand_helper_session=restored")
        let auth = TestAuthenticationClient()
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth)
        await state.restoreSession()
        XCTAssertEqual(state.entry, .main)
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
        XCTAssertEqual(state.entry, .login)
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
        XCTAssertEqual(expired.entry, .login)
        XCTAssertNil(expiredSession.cookie)
        XCTAssertEqual(expired.authenticationStatus, .expired)
        XCTAssertNil(expired.verifiedAccount.owner)

        let offlineSession = TestSessionStore()
        offlineSession.save(cookie: "pending")
        let offlineAuth = TestAuthenticationClient()
        offlineAuth.verifyError = APIError.connection
        let offline = AppState(api: MockAPIClient(), sessionStore: offlineSession, authentication: offlineAuth)
        await offline.restoreSession()
        XCTAssertEqual(offline.entry, .offline)
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
    func testConfirmedLoginFailuresPublishOneClassifiedFeedbackEventPerAttempt() async throws {
        let auth = TestAuthenticationClient()
        let state = AppState(api: MockAPIClient(), sessionStore: TestSessionStore(), authentication: auth)

        auth.loginError = APIError.unauthorized(message: "用户名或密码错误")
        await state.login(username: "student", password: "wrong")
        let credentials = try XCTUnwrap(state.loginFailureFeedback)
        XCTAssertEqual(credentials.feedback, .credentialsRejected)

        auth.loginError = APIError.connection
        await state.login(username: "student", password: "example")
        let connection = try XCTUnwrap(state.loginFailureFeedback)
        XCTAssertEqual(connection.feedback, .recoverable)
        XCTAssertNotEqual(credentials.id, connection.id)
    }

    @MainActor
    func testRotatedCookieRequiresReverificationAndSameAccount() async {
        let session = TestSessionStore()
        session.save(cookie: "session=old")
        let auth = TestAuthenticationClient()
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth)
        await state.restoreSession()
        XCTAssertTrue(state.canAccessPrivateData)

        session.save(cookie: "session=rotated")
        XCTAssertFalse(state.canAccessPrivateData)
        await state.reverifyRotatedSession()
        XCTAssertTrue(state.canAccessPrivateData)
        XCTAssertEqual(state.verifiedAccount.owner, "user:student")

        session.save(cookie: "session=other")
        auth.verifiedUsername = "other"
        await state.reverifyRotatedSession()
        XCTAssertFalse(state.canAccessPrivateData)
        XCTAssertEqual(state.authenticationStatus, .expired)
        XCTAssertNil(session.cookie)
    }

    @MainActor
    func testRestorationPersistsCookieReturnedByAuthMe() async {
        let session = TestSessionStore()
        session.save(cookie: "session=old")
        let auth = TestAuthenticationClient()
        auth.rotationCookie = "session=renewed"
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth)
        await state.restoreSession()
        XCTAssertEqual(session.cookie, "session=renewed")
        XCTAssertTrue(state.canAccessPrivateData)
        XCTAssertEqual(try? state.requireCurrentAccount(revision: state.authenticationRevision), "user:student")
    }

    @MainActor
    func testFailedCredentialRemovalBlocksRestorationUntilRetry() async {
        let suite = "credential-removal-\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suite) else { XCTFail("Cannot create test defaults"); return }
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = TestSessionStore()
        session.save(cookie: "session=old")
        let auth = TestAuthenticationClient()
        let state = AppState(api: MockAPIClient(), sessionStore: session,
                             authentication: auth, preferences: preferences)
        await state.restoreSession()
        session.failClear = true
        await state.logout()
        XCTAssertEqual(state.entry, .credentialRecovery)
        XCTAssertFalse(state.canAccessPrivateData)
        XCTAssertEqual(state.authenticationStatus, .signedOut)
        XCTAssertNotNil(state.credentialRemovalError)
        XCTAssertEqual(session.cookie, "session=old")

        let relaunched = AppState(api: MockAPIClient(), sessionStore: session,
                                  authentication: auth, preferences: preferences)
        XCTAssertEqual(relaunched.entry, .credentialRecovery)
        await relaunched.restoreSession()
        XCTAssertFalse(relaunched.isAuthenticated)
        XCTAssertNotNil(relaunched.credentialRemovalError)
        session.failClear = false
        XCTAssertTrue(relaunched.retryCredentialRemoval())
        XCTAssertNil(session.cookie)
        XCTAssertNil(relaunched.credentialRemovalError)
        XCTAssertEqual(relaunched.entry, .login)
    }

    @MainActor
    func testServerLogoutFailureDoesNotReportCredentialRemovalFailure() async {
        let session = TestSessionStore()
        session.save(cookie: "session=valid")
        let auth = TestAuthenticationClient()
        auth.logoutError = URLError(.notConnectedToInternet)
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth)
        await state.restoreSession()
        await state.logout()
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertNil(session.cookie)
        XCTAssertNil(state.credentialRemovalError)
    }

    @MainActor
    func testLogoutDuringPendingLoginKeepsFullScreenGate() async {
        let session = TestSessionStore()
        let auth = TestAuthenticationClient()
        auth.loginWait = true
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth)
        let pending = Task { await state.login(username: "student", password: "example") }
        await auth.waitForLoginStart()
        await state.logout()
        auth.resumeLogin()
        await pending.value
        XCTAssertEqual(state.entry, .login)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertNil(session.cookie)
    }

    @MainActor
    func testFullScreenGateRequiresVerifiedSessionAndOfflineRetry() async {
        let empty = AppState(api: MockAPIClient(), sessionStore: TestSessionStore(),
                             authentication: TestAuthenticationClient())
        XCTAssertEqual(empty.entry, .login)
        await empty.restoreSession()
        XCTAssertEqual(empty.entry, .login)

        let session = TestSessionStore()
        session.save(cookie: "session=pending")
        let auth = TestAuthenticationClient()
        auth.verifyError = APIError.connection
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth)
        XCTAssertEqual(state.entry, .verifying)
        XCTAssertFalse(state.canAccessPrivateData)
        await state.restoreSession()
        XCTAssertEqual(state.entry, .offline)
        XCTAssertEqual(session.cookie, "session=pending")
        auth.verifyError = nil
        await state.retrySessionVerification()
        XCTAssertEqual(state.entry, .main)
        XCTAssertTrue(state.canAccessPrivateData)
    }

    @MainActor
    func testOrdinaryAPIResponseRotationAutomaticallyGatesAndReverifies() async throws {
        let session = TestSessionStore()
        session.save(cookie: "session=old")
        let auth = TestAuthenticationClient()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthenticationURLProtocol.self]
        let identifier = AuthenticationURLProtocol.register { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=old")
            return try self.response(request, 200,
                #"{"success":true,"data":{"username":"student"}}"#,
                cookie: "session=rotated; Path=/; HttpOnly")
        }
        configuration.httpAdditionalHeaders = ["X-Authentication-Test-ID": identifier]
        let api = APIClient(configuration: .development, sessionStore: session,
                            session: URLSession(configuration: configuration))
        let state = AppState(api: api, sessionStore: session, authentication: auth)
        await state.restoreSession()
        XCTAssertEqual(state.entry, .main)
        auth.verifyWait = true
        let _: AuthIdentity = try await api.request("GET", path: "/api/v1/auth/me")
        await auth.waitForVerifyStart(count: 2)
        XCTAssertEqual(state.entry, .verifying)
        XCTAssertFalse(state.canAccessPrivateData)
        auth.resumeVerify()
        for _ in 0..<1_000 {
            if state.entry == .main { break }
            await Task.yield()
        }
        XCTAssertEqual(state.entry, .main)
        XCTAssertEqual(session.cookie, "session=rotated")
        XCTAssertEqual(state.verifiedAccount.owner, "user:student")
    }

    @MainActor
    func testCancelledLoginTaskDoesNotStartRequest() async {
        let auth = TestAuthenticationClient()
        let state = AppState(api: MockAPIClient(), sessionStore: TestSessionStore(), authentication: auth)
        let pending = Task { await state.login(username: "student", password: "example") }
        pending.cancel()
        await pending.value
        XCTAssertEqual(auth.loginCount, 0)
        XCTAssertFalse(state.isAuthenticated)
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
    func testEditorRevisionCannotWriteAfterLogoutAndAccountSwitch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = TestSessionStore()
        session.save(cookie: "session=alice")
        let auth = TestAuthenticationClient()
        auth.verifiedUsername = "alice"
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth)
        await state.restoreSession()
        let store = LocalScheduleStore(session: session, account: state.verifiedAccount, directory: folder)
        let editorRevision = state.authenticationRevision
        try store.save(CustomSchedule(id: 0, title: "Alice 安排", date: "2026-10-23", time: "09:00"))

        await state.logout()
        XCTAssertThrowsError(try state.requireCurrentAccount(revision: editorRevision))
        XCTAssertThrowsError(try store.save(CustomSchedule(id: 0, title: "旧编辑器写入", date: "2026-10-23", time: "10:00")))

        await state.login(username: "bob", password: "example")
        XCTAssertTrue(state.canAccessPrivateData)
        XCTAssertThrowsError(try state.requireCurrentAccount(revision: editorRevision))
        XCTAssertTrue(try store.all().isEmpty)
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
        let model = TodayViewModel(repository: repository, wallpaperStore: WallpaperStore(session: session,
                                                                                        account: VerifiedAccountContext(),
                                                                                        directory: folder))

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
        let model = TodayViewModel(repository: repository, wallpaperStore: WallpaperStore(session: session,
                                                                                        account: state.verifiedAccount,
                                                                                        directory: folder))

        model.load(allowPrivateCache: false)
        XCTAssertNil(model.snapshot)
        await state.login(username: "student", password: "example")
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.entry, .main)
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
        let identifier = AuthenticationURLProtocol.register(handler)
        configuration.httpAdditionalHeaders = ["X-Authentication-Test-ID": identifier]
        return AuthenticationClient(session: URLSession(configuration: configuration))
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream,
                                   "Login request has neither httpBody nor httpBodyStream")
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { bytes -> Int in
                guard let address = bytes.baseAddress else { return -1 }
                return stream.read(address, maxLength: bytes.count)
            }
            if count < 0 {
                let error = stream.streamError ?? URLError(.cannotDecodeRawData)
                XCTFail("Could not read streamed login request body: \(error)")
                throw error
            }
            if count == 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }

    private func response(_ request: URLRequest, _ status: Int, _ json: String,
                          cookie: String? = nil) throws -> (HTTPURLResponse, Data) {
        let headers = cookie.map { ["Set-Cookie": $0] }
        let url = try XCTUnwrap(request.url, "Authentication request has no URL")
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status,
                                                      httpVersion: nil, headerFields: headers),
                                     "Could not construct authentication response")
        return (response, Data(json.utf8))
    }
}

private final class AuthenticationURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

    static func register(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> String {
        let identifier = UUID().uuidString
        lock.lock()
        handlers[identifier] = handler
        lock.unlock()
        return identifier
    }

    private static func handler(for identifier: String) -> ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[identifier]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let identifier = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Authentication-Test-ID"),
                                           "Authentication test request has no handler ID")
            let handler = try XCTUnwrap(Self.handler(for: identifier),
                                        "Authentication URLProtocol handler is missing")
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class TestSessionStore: SessionStore {
    private(set) var cookie: String?
    var failClear = false
    func save(cookie: String) { self.cookie = cookie }
    @discardableResult func clear() -> Bool {
        guard !failClear else { return false }
        cookie = nil
        return true
    }
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
    var logoutError: Error?
    var verifiedUsername = "student"
    var rotationCookie: String?
    var loginWait = false
    var verifyWait = false
    var loginCount = 0
    var verifyCount = 0
    var logoutCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var verifyContinuation: CheckedContinuation<Void, Never>?

    func login(username: String, password: String) async throws -> (cookie: String, identity: VerifiedIdentity) {
        loginCount += 1
        if loginWait { await withCheckedContinuation { continuation = $0 } }
        if let loginError { throw loginError }
        return ("hand_helper_session=new", VerifiedIdentity(authenticated: true, username: username))
    }
    func verify(cookie: String) async throws -> VerifiedIdentity {
        verifyCount += 1
        if verifyWait { await withCheckedContinuation { verifyContinuation = $0 } }
        if let verifyError { throw verifyError }
        return VerifiedIdentity(authenticated: true, username: verifiedUsername)
    }
    func verifySession(cookie: String) async throws -> (cookie: String, identity: VerifiedIdentity) {
        let identity = try await verify(cookie: cookie)
        return (rotationCookie ?? cookie, identity)
    }
    func logout(cookie: String) async throws {
        logoutCount += 1
        if let logoutError { throw logoutError }
    }
    func resumeLogin() { continuation?.resume(); continuation = nil }
    func resumeVerify() { verifyContinuation?.resume(); verifyContinuation = nil }
    func waitForVerifyStart(count: Int) async {
        for _ in 0..<1_000 {
            if verifyCount >= count && verifyContinuation != nil { return }
            await Task.yield()
        }
        XCTFail("Verification did not begin")
    }
    func waitForLoginStart() async {
        for _ in 0..<1_000 {
            if loginCount > 0 && continuation != nil { return }
            await Task.yield()
        }
        XCTFail("Login did not begin")
    }
}
