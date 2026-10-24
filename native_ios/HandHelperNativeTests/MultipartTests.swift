import Foundation
import XCTest
@testable import HandHelperNative

final class MultipartTests: XCTestCase {
    func testPayloadSizeAndCanonicalFileNames() throws {
        let exact = try MultipartFilePayload(data: Data(repeating: 0x7A, count: 2_000_000),
                                             fileExtension: .xls)
        XCTAssertEqual(exact.data.count, 2_000_000)
        XCTAssertEqual(exact.safeFileName, "upload.xls")
        XCTAssertEqual(exact.mimeType, "application/vnd.ms-excel")
        XCTAssertEqual(try MultipartFilePayload(data: Data([1]), fileExtension: .html).mimeType,
                       "text/html")
        XCTAssertEqual(try MultipartFilePayload(data: Data([1]), fileExtension: .htm).safeFileName,
                       "upload.htm")
        XCTAssertThrowsError(try MultipartFilePayload(data: Data(), fileExtension: .xls)) {
            XCTAssertEqual($0 as? MultipartUploadError, .emptyFile)
        }
        XCTAssertThrowsError(try MultipartFilePayload(data: Data(repeating: 0, count: 2_000_001),
                                                       fileExtension: .xls)) {
            XCTAssertEqual($0 as? MultipartUploadError, .fileTooLarge)
        }
    }

    func testMultipartWireFormatPreservesBinaryBytesAndCredentials() async throws {
        let original = Data([0, 1, 2, 13, 10, 0xFF])
        let payload = try MultipartFilePayload(data: original, fileExtension: .xls)
        let store = UploadTestSessionStore(cookie: "session=existing")
        let client = makeClient(store: store) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/timetable/import-file")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=existing")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://hand.zhangzh.cc")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.timeoutInterval, 45)
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            XCTAssertFalse(boundary.isEmpty)
            let body = try Self.body(of: request)
            let prefix = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"upload.xls\"\r\nContent-Type: application/vnd.ms-excel\r\n\r\n".utf8)
            let suffix = Data("\r\n--\(boundary)--\r\n".utf8)
            XCTAssertTrue(body.starts(with: prefix))
            XCTAssertTrue(body.suffix(suffix.count).elementsEqual(suffix))
            XCTAssertEqual(Data(body.dropFirst(prefix.count).dropLast(suffix.count)), original)
            return try Self.response(for: request, status: 200,
                                     json: #"{"success":true,"data":{"username":"tester"}}"#)
        }
        let result: AuthIdentity = try await client.uploadMultipart(
            path: "/api/v1/timetable/import-file", file: payload)
        XCTAssertEqual(result.username, "tester")
    }

    func testBoundaryIsRandomAndGradeTermIsEncodedAsQuery() async throws {
        let store = UploadTestSessionStore(cookie: "session=test")
        let payload = try MultipartFilePayload(data: Data("<table></table>".utf8),
                                               fileExtension: .html)
        let lock = NSLock()
        var boundaries: [String] = []
        let client = makeClient(store: store) { request in
            XCTAssertEqual(request.url?.path, "/api/v1/grades/import-file")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems
            XCTAssertEqual(query?.count, 1)
            XCTAssertEqual(query?.first?.name, "term_id")
            XCTAssertEqual(query?.first?.value, "2025-2026-1")
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            lock.lock()
            boundaries.append(contentType)
            lock.unlock()
            let body = try Self.body(of: request)
            XCTAssertNotNil(body.range(of: Data("filename=\"upload.html\"".utf8)))
            XCTAssertNotNil(body.range(of: Data("Content-Type: text/html".utf8)))
            return try Self.response(for: request, status: 200,
                                     json: #"{"success":true,"data":{"username":"tester"}}"#)
        }
        let _: AuthIdentity = try await client.uploadMultipart(
            path: "/api/v1/grades/import-file", file: payload, termID: "2025-2026-1")
        let _: AuthIdentity = try await client.uploadMultipart(
            path: "/api/v1/grades/import-file", file: payload, termID: "2025-2026-1")
        XCTAssertEqual(boundaries.count, 2)
        XCTAssertNotEqual(boundaries[0], boundaries[1])
    }

    func testInvalidTermAndUnsafePathFailBeforeNetwork() async throws {
        let payload = try MultipartFilePayload(data: Data([1]), fileExtension: .xls)
        let client = makeClient(store: UploadTestSessionStore()) { _ in
            XCTFail("Invalid local input must not reach URLSession")
            throw URLError(.badURL)
        }
        do {
            let _: AuthIdentity = try await client.uploadMultipart(
                path: "/api/v1/grades/import-file", file: payload, termID: "bad\r\nheader")
            XCTFail("Expected invalid term")
        } catch let error as MultipartUploadError {
            XCTAssertEqual(error, .invalidTermID)
        }
        do {
            let _: AuthIdentity = try await client.uploadMultipart(path: "//evil.test/upload", file: payload)
            XCTFail("Expected invalid URL")
        } catch let error as APIError {
            XCTAssertEqual(error, .invalidConfiguration)
        }
    }

    func testNonJSON401ClearsMatchingCookieAndEmitsEvent() async throws {
        let store = UploadTestSessionStore(cookie: "session=expired")
        let client = makeClient(store: store) { request in
            try Self.response(for: request, status: 401, json: "not JSON")
        }
        var event: APISessionEvent?
        client.onSessionEvent = { event = $0 }
        let payload = try MultipartFilePayload(data: Data([1]), fileExtension: .xls)
        do {
            let _: AuthIdentity = try await client.uploadMultipart(path: "/api/v1/timetable/import-file",
                                                                   file: payload)
            XCTFail("Expected 401")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized(message: "登录状态已失效，请重新登录"))
        }
        XCTAssertNil(store.cookie)
        guard case .unauthorized(let previous)? = event else {
            return XCTFail("Expected unauthorized session event")
        }
        XCTAssertEqual(previous, "session=expired")
    }

    func test422ServerMessageAndMalformedSuccessEnvelope() async throws {
        let payload = try MultipartFilePayload(data: Data([1]), fileExtension: .xls)
        let rejected = makeClient(store: UploadTestSessionStore()) { request in
            try Self.response(for: request, status: 422,
                              json: #"{"success":false,"error":{"message":"文件格式错误"}}"#)
        }
        do {
            let _: AuthIdentity = try await rejected.uploadMultipart(path: "/api/v1/timetable/import-file",
                                                                     file: payload)
            XCTFail("Expected 422")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 422, message: "文件格式错误"))
        }
        let malformed = makeClient(store: UploadTestSessionStore()) { request in
            try Self.response(for: request, status: 200, json: "not JSON")
        }
        do {
            let _: AuthIdentity = try await malformed.uploadMultipart(path: "/api/v1/timetable/import-file",
                                                                      file: payload)
            XCTFail("Expected invalid response data")
        } catch let error as APIError {
            XCTAssertEqual(error, .invalidData(status: 200))
        }
    }

    func testSetCookieRotationAndJSONRequestRegression() async throws {
        let store = UploadTestSessionStore(cookie: "session=old")
        let client = makeClient(store: store) { request in
            if request.value(forHTTPHeaderField: "Content-Type") == "application/json" {
                XCTAssertEqual(request.timeoutInterval, 20)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=new")
            }
            return try Self.response(for: request, status: 200,
                                     json: #"{"success":true,"data":{"username":"tester"}}"#,
                                     headers: ["Set-Cookie": "session=new; Path=/; HttpOnly"])
        }
        var event: APISessionEvent?
        client.onSessionEvent = { event = $0 }
        let payload = try MultipartFilePayload(data: Data([1]), fileExtension: .xls)
        let uploaded: AuthIdentity = try await client.uploadMultipart(
            path: "/api/v1/timetable/import-file", file: payload)
        XCTAssertEqual(uploaded.username, "tester")
        XCTAssertEqual(store.cookie, "session=new")
        guard case .rotated(let previous, let current)? = event else {
            return XCTFail("Expected rotated session event")
        }
        XCTAssertEqual(previous, "session=old")
        XCTAssertEqual(current, "session=new")
        let json: AuthIdentity = try await client.request("POST", path: "/api/v1/auth/me",
                                                          body: Data("{}".utf8))
        XCTAssertEqual(json.username, "tester")
    }

    func testConnectionTimeoutAndCancellationAreDistinct() async throws {
        let payload = try MultipartFilePayload(data: Data([1]), fileExtension: .xls)
        for (urlError, expected) in [(URLError.Code.timedOut, APIError.timeout),
                                     (.cannotConnectToHost, .connection)] {
            let client = makeClient(store: UploadTestSessionStore()) { _ in throw URLError(urlError) }
            do {
                let _: AuthIdentity = try await client.uploadMultipart(
                    path: "/api/v1/timetable/import-file", file: payload)
                XCTFail("Expected network error")
            } catch let error as APIError {
                XCTAssertEqual(error, expected)
            }
        }
        let cancelled = makeClient(store: UploadTestSessionStore()) { _ in throw URLError(.cancelled) }
        do {
            let _: AuthIdentity = try await cancelled.uploadMultipart(
                path: "/api/v1/timetable/import-file", file: payload)
            XCTFail("Expected cancellation")
        } catch is CancellationError { /* Expected: no retry or server outcome claim. */ }
    }

    func testCancellingInFlightUploadDoesNotRetryOrClaimServerOutcome() async throws {
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let store = UploadTestSessionStore(cookie: "session=current")
        let client = makeClient(store: store) { _ in
            entered.signal()
            guard resume.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            throw URLError(.cancelled)
        }
        let payload = try MultipartFilePayload(data: Data([1]), fileExtension: .xls)
        let pending = Task { () -> Error? in
            do {
                let _: AuthIdentity = try await client.uploadMultipart(
                    path: "/api/v1/timetable/import-file", file: payload)
                return nil
            } catch { return error }
        }
        let reached = await Task.detached { entered.wait(timeout: .now() + 5) }.value
        guard reached == .success else {
            resume.signal()
            pending.cancel()
            XCTFail("Upload never reached URLProtocol")
            return
        }
        pending.cancel()
        resume.signal()
        let outcome = await pending.value
        XCTAssertTrue(outcome is CancellationError)
        XCTAssertEqual(store.cookie, "session=current")
        XCTAssertEqual(entered.wait(timeout: .now()), .timedOut, "Cancelled POST must not retry")
    }

    func testLate401CannotClearNewCookie() async throws {
        let store = UploadTestSessionStore(cookie: "session=old")
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let client = makeClient(store: store) { request in
            entered.signal()
            guard resume.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            return try Self.response(for: request, status: 401, json: "not JSON")
        }
        let payload = try MultipartFilePayload(data: Data([1]), fileExtension: .xls)
        let pending = Task { () -> Error? in
            do {
                let _: AuthIdentity = try await client.uploadMultipart(
                    path: "/api/v1/timetable/import-file", file: payload)
                return nil
            } catch { return error }
        }
        let reached = await Task.detached { entered.wait(timeout: .now() + 5) }.value
        guard reached == .success else {
            resume.signal()
            pending.cancel()
            XCTFail("Upload never reached URLProtocol")
            return
        }
        store.save(cookie: "session=new")
        resume.signal()
        let outcome = await pending.value
        XCTAssertEqual(outcome as? MultipartUploadError, .sessionChanged)
        XCTAssertEqual(store.cookie, "session=new")
    }

    func testLateSuccessAfterSessionInvalidationIsNotReturnedOrRotated() async throws {
        let store = UploadTestSessionStore(cookie: "session=old")
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let client = makeClient(store: store) { request in
            entered.signal()
            guard resume.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            return try Self.response(for: request, status: 200,
                                     json: #"{"success":true,"data":{"username":"old"}}"#,
                                     headers: ["Set-Cookie": "session=rotated-old; Path=/"])
        }
        let payload = try MultipartFilePayload(data: Data([1]), fileExtension: .xls)
        let pending = Task { () -> Error? in
            do {
                let _: AuthIdentity = try await client.uploadMultipart(
                    path: "/api/v1/timetable/import-file", file: payload)
                return nil
            } catch { return error }
        }
        let reached = await Task.detached { entered.wait(timeout: .now() + 5) }.value
        guard reached == .success else {
            resume.signal()
            pending.cancel()
            XCTFail("Upload never reached URLProtocol")
            return
        }
        client.invalidatePendingSessionRequests()
        store.save(cookie: "session=new")
        resume.signal()
        let outcome = await pending.value
        XCTAssertEqual(outcome as? MultipartUploadError, .sessionChanged)
        XCTAssertEqual(store.cookie, "session=new")
    }

    func testProtocolUploadCanBeMockedWithoutNetwork() async throws {
        let mock: any APIClientProtocol = UploadProtocolMock()
        let payload = try MultipartFilePayload(data: Data([1]), fileExtension: .htm)
        let value: AuthIdentity = try await mock.uploadMultipart(
            path: "/api/v1/grades/import-file", file: payload, termID: nil)
        XCTAssertEqual(value.username, "mock")
    }

    private func makeClient(store: UploadTestSessionStore,
                            handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MultipartURLProtocol.self]
        let identifier = MultipartURLProtocol.register(handler)
        configuration.httpAdditionalHeaders = ["X-Multipart-Test-ID": identifier]
        return APIClient(configuration: .development, sessionStore: store,
                         session: URLSession(configuration: configuration))
    }

    private static func response(for request: URLRequest, status: Int, json: String,
                                 headers: [String: String] = [:]) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status,
                                                     httpVersion: nil, headerFields: headers))
        return (response, Data(json.utf8))
    }

    private static func body(of request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream, "Missing request body and body stream")
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? APIError.invalidResponse }
            if count == 0 { break }
            result.append(contentsOf: buffer[..<count])
        }
        return result
    }
}

private final class UploadTestSessionStore: SessionStore {
    private let lock = NSLock()
    private var storedCookie: String?
    init(cookie: String? = nil) { storedCookie = cookie }
    var cookie: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedCookie
    }
    func save(cookie: String) {
        lock.lock()
        storedCookie = cookie
        lock.unlock()
    }
    @discardableResult func clear() -> Bool {
        lock.lock()
        storedCookie = nil
        lock.unlock()
        return true
    }
}

private final class MultipartURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

    static func register(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> String {
        let identifier = UUID().uuidString
        lock.lock()
        handlers[identifier] = handler
        lock.unlock()
        return identifier
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let identifier = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Multipart-Test-ID"))
            Self.lock.lock()
            let handler = Self.handlers[identifier]
            Self.lock.unlock()
            let (response, data) = try XCTUnwrap(handler)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private struct UploadProtocolMock: APIClientProtocol {
    func request<Value: Decodable>(_ method: String, path: String, body: Data?,
                                   preserveSessionOnPasswordError: Bool) async throws -> Value {
        throw APIError.invalidConfiguration
    }

    func uploadMultipart<Value: Decodable>(path: String, file: MultipartFilePayload,
                                           termID: String?) async throws -> Value {
        let envelope = Data(#"{"success":true,"data":{"username":"mock"}}"#.utf8)
        return try XCTUnwrap(JSONDecoder().decode(APIEnvelope<Value>.self, from: envelope).data)
    }
}
