import Foundation
import XCTest
@testable import HandHelperNative

final class GradeImportTests: XCTestCase {
    private let previewJSON = #"{"source_term_id":"2025-2026-2","grades":[{"course_code":"CS101","course_name":"算法","course_type":"必修","credits":3.5,"score":"优秀","final_exam_score":"91","usual_score":"88","grade_point":4.0,"weighted_grade_point":14.0,"exam_type":"考试","makeup_flag":false,"retake_flag":true,"source_grade_id":"source-1"}]}"#

    func testPreviewDecodesEveryBackendField() throws {
        let preview = try JSONDecoder().decode(GradeImportPreview.self, from: Data(previewJSON.utf8))
        XCTAssertEqual(preview.sourceTermID, "2025-2026-2")
        XCTAssertEqual(preview.grades.count, 1)
        let grade = try XCTUnwrap(preview.grades.first)
        XCTAssertEqual(grade.courseCode, "CS101")
        XCTAssertEqual(grade.courseName, "算法")
        XCTAssertEqual(grade.courseType, "必修")
        XCTAssertEqual(grade.credits, 3.5)
        XCTAssertEqual(grade.score, "优秀")
        XCTAssertEqual(grade.finalExamScore, "91")
        XCTAssertEqual(grade.usualScore, "88")
        XCTAssertEqual(grade.gradePoint, 4)
        XCTAssertEqual(grade.weightedGradePoint, 14)
        XCTAssertEqual(grade.examType, "考试")
        XCTAssertFalse(grade.makeupFlag)
        XCTAssertTrue(grade.retakeFlag)
        XCTAssertEqual(grade.sourceGradeID, "source-1")
    }

    @MainActor
    func testServiceUsesPreviewEndpointAndOptionalTermOnly() async throws {
        let api = GradeAPIStub(json: previewJSON)
        let service = GradeImportService(api: api)
        let file = try MultipartFilePayload(data: Data([0, 1, 255]), fileExtension: .html)
        let result = try await service.preview(file: file, termID: "2025-2026-2")
        XCTAssertEqual(result.grades.first?.courseName, "算法")
        XCTAssertEqual(api.paths, ["/api/v1/grades/import-file"])
        XCTAssertEqual(api.termIDs, ["2025-2026-2"])
        XCTAssertEqual(api.data, [Data([0, 1, 255])])
        _ = try await service.preview(file: file, termID: nil)
        XCTAssertEqual(api.termIDs.count, 2)
        XCTAssertNil(api.termIDs[1])
        XCTAssertEqual(api.paths.count, 2, "No import-confirm request may be made")
    }

    @MainActor
    func testAPIClientDecodesPreviewEnvelopeWithCookieAndTerm() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GradeURLProtocol.self]
        let testID = GradeURLProtocol.register { request in
            let requestURL = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(requestURL.path, "/api/v1/grades/import-file")
            let query = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first?.value, "2025-2026-2")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=alice")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://hand.zhangzh.cc")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: requestURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            let envelope = #"{"success":true,"data":{"source_term_id":"2025-2026-2","grades":[{"course_code":"CS101","course_name":"算法","course_type":"必修","credits":3.5,"score":"优秀","final_exam_score":"91","usual_score":"88","grade_point":4.0,"weighted_grade_point":14.0,"exam_type":"考试","makeup_flag":false,"retake_flag":true,"source_grade_id":"source-1"}]},"error":null}"#
            return (response, Data(envelope.utf8))
        }
        defer { GradeURLProtocol.unregister(testID) }
        configuration.httpAdditionalHeaders = ["X-Grade-Test-ID": testID]
        let session = GradeSessionStub(cookie: "session=alice")
        let client = APIClient(configuration: .development, sessionStore: session,
                               session: URLSession(configuration: configuration))
        let payload = try MultipartFilePayload(data: Data([1]), fileExtension: .xls)
        let preview = try await GradeImportService(api: client).preview(file: payload,
                                                                         termID: "2025-2026-2")
        XCTAssertEqual(preview.grades.first?.sourceGradeID, "source-1")
    }

    @MainActor
    func testReaderAcceptsThreeExtensionsAndExactSizeLimit() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reader = GradeFileReader()
        for ext in ["xls", "html", "htm"] {
            let url = folder.appendingPathComponent("grade.\(ext)")
            try Data([1, 2, 3]).write(to: url)
            let payload = try await reader.read(from: url)
            XCTAssertEqual(payload.fileExtension.rawValue, ext)
            XCTAssertEqual(payload.data, Data([1, 2, 3]))
        }
        let boundary = folder.appendingPathComponent("maximum.XLS")
        try Data(repeating: 7, count: MultipartFilePayload.maximumFileSize).write(to: boundary)
        let exact = try await reader.read(from: boundary)
        XCTAssertEqual(exact.data.count, MultipartFilePayload.maximumFileSize)
    }

    @MainActor
    func testReaderRejectsWrongExtensionEmptyOversizeAndMissingFile() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reader = GradeFileReader()
        let wrong = folder.appendingPathComponent("grade.txt")
        try Data([1]).write(to: wrong)
        do { _ = try await reader.read(from: wrong); XCTFail("Wrong extension accepted") }
        catch let error as GradeFileError { XCTAssertEqual(error, .wrongExtension) }

        let empty = folder.appendingPathComponent("empty.xls")
        try Data().write(to: empty)
        do { _ = try await reader.read(from: empty); XCTFail("Empty file accepted") }
        catch let error as MultipartUploadError { XCTAssertEqual(error, .emptyFile) }

        let large = folder.appendingPathComponent("large.html")
        try Data(repeating: 1, count: MultipartFilePayload.maximumFileSize + 1).write(to: large)
        do { _ = try await reader.read(from: large); XCTFail("Oversize file accepted") }
        catch let error as MultipartUploadError { XCTAssertEqual(error, .fileTooLarge) }

        do { _ = try await reader.read(from: folder.appendingPathComponent("missing.htm")); XCTFail("Missing file accepted") }
        catch let error as GradeFileError { XCTAssertEqual(error, .unreadable) }
    }

    @MainActor
    func testTermValidationAndPickerCancellationCannotUpload() async throws {
        let state = await makeState()
        let service = GradeServiceStub(preview: try samplePreview())
        let model = GradeImportViewModel(state: state, reader: GradeReaderStub(), service: service)
        model.termID = "2025-2026-3"
        await model.select(URL(fileURLWithPath: "/grade.xls"))
        XCTAssertFalse(model.canUpload)
        model.startUpload()
        XCTAssertEqual(service.callCount, 0)
        model.termID = " 2025-2026-2 "
        XCTAssertEqual(model.normalizedTermID, "2025-2026-2")
        XCTAssertTrue(model.canUpload)
        model.selectionCancelled()
        XCTAssertEqual(service.callCount, 0)
        XCTAssertNil(state.pendingGradeImport)
    }

    @MainActor
    func testSuccessfulPreviewIsReadOnlyAndCanBeDismissed() async throws {
        let state = await makeState()
        let service = GradeServiceStub(preview: try samplePreview())
        let model = GradeImportViewModel(state: state, reader: GradeReaderStub(), service: service)
        await model.select(URL(fileURLWithPath: "/grade.html"))
        model.startUpload()
        model.startUpload() // A second tap cannot send another POST.
        await model.waitForUploadCompletion()
        guard let phase = state.visibleGradeImport?.phase,
              case .ready(let result) = phase else {
            return XCTFail("Successful parse must produce a visible preview")
        }
        XCTAssertEqual(result.grades.first?.sourceGradeID, "source-1")
        XCTAssertEqual(service.callCount, 1)
        model.discardResult()
        XCTAssertNil(state.pendingGradeImport)
    }

    @MainActor
    func testTimeoutAnd422KeepNoFalsePreviewOrAutomaticRetry() async throws {
        for failure in [APIError.timeout, APIError.server(status: 422, message: "无法解析成绩文件")] {
            let state = await makeState()
            let service = GradeServiceStub(preview: try samplePreview())
            service.error = failure
            let model = GradeImportViewModel(state: state, reader: GradeReaderStub(), service: service)
            await model.select(URL(fileURLWithPath: "/grade.xls"))
            model.startUpload()
            await model.waitForUploadCompletion()
            guard let phase = state.visibleGradeImport?.phase,
                  case .failed(let message) = phase else {
                return XCTFail("Server failure must not become a preview")
            }
            XCTAssertEqual(message, failure.localizedDescription)
            XCTAssertEqual(service.callCount, 1)
            XCTAssertFalse(model.canUpload)
        }
    }

    @MainActor
    func test401RevokesIdentityAndHidesPreview() async throws {
        let state = await makeState()
        let service = GradeServiceStub(preview: try samplePreview())
        service.error = APIError.unauthorized(message: "登录状态已失效")
        let model = GradeImportViewModel(state: state, reader: GradeReaderStub(), service: service)
        await model.select(URL(fileURLWithPath: "/grade.xls"))
        model.startUpload()
        await model.waitForUploadCompletion()
        XCTAssertFalse(state.canAccessPrivateData)
        XCTAssertNil(state.pendingGradeImport)
    }

    @MainActor
    func testLate401FromOldCookieCannotRevokeRotatedSession() async throws {
        let session = GradeSessionStub(cookie: "session=alice")
        let state = AppState(api: MockAPIClient(), sessionStore: session,
                             authentication: GradeAuthStub(username: "alice"))
        await state.restoreSession()
        let gate = GradeGate()
        let service = GradeServiceStub(preview: try samplePreview())
        service.gate = gate
        service.error = .unauthorized(message: "旧请求已失效")
        let model = GradeImportViewModel(state: state, reader: GradeReaderStub(), service: service)
        await model.select(URL(fileURLWithPath: "/grade.xls"))
        model.startUpload()
        defer { gate.release() }
        await fulfillment(of: [gate.arrived], timeout: 3)
        session.save(cookie: "session=rotated")
        gate.release()
        await model.waitForUploadCompletion()
        XCTAssertEqual(session.cookie, "session=rotated")
        await state.reverifyRotatedSession()
        XCTAssertTrue(state.canAccessPrivateData)
        guard let phase = state.visibleGradeImport?.phase,
              case .failed = phase else {
            return XCTFail("Old-cookie 401 must not sign out the reverified account")
        }
    }

    @MainActor
    func testLateResponseAfterAccountSwitchCannotReopenPreview() async throws {
        let session = GradeSessionStub(cookie: "session=alice")
        let state = AppState(api: MockAPIClient(), sessionStore: session,
                             authentication: GradeAuthStub(username: "alice"))
        await state.restoreSession()
        let gate = GradeGate()
        let service = GradeServiceStub(preview: try samplePreview())
        service.gate = gate
        let model = GradeImportViewModel(state: state, reader: GradeReaderStub(), service: service)
        await model.select(URL(fileURLWithPath: "/grade.xls"))
        model.startUpload()
        defer { gate.release() }
        await fulfillment(of: [gate.arrived], timeout: 3)
        await state.logout()
        await state.login(username: "bob", password: "test-password")
        gate.release()
        await model.waitForUploadCompletion()
        XCTAssertNil(state.pendingGradeImport)
        XCTAssertEqual(try state.requireCurrentAccount(revision: state.authenticationRevision), "user:bob")
        XCTAssertNil(state.visibleGradeImport)
    }

    @MainActor
    func testLateFileReadAfterAccountSwitchCannotSelectOldFile() async throws {
        let state = await makeState()
        let gate = GradeGate()
        let model = GradeImportViewModel(state: state, reader: GradeReaderGateStub(gate: gate),
                                         service: GradeServiceStub(preview: try samplePreview()))
        let selection = Task { await model.select(URL(fileURLWithPath: "/grade.xls")) }
        defer { gate.release() }
        await fulfillment(of: [gate.arrived], timeout: 3)
        await state.logout()
        model.authenticationDidChange()
        await state.login(username: "bob", password: "test-password")
        gate.release()
        await selection.value
        XCTAssertNil(model.selectedFileName)
        XCTAssertFalse(model.canUpload)
    }

    @MainActor
    func testCancelledUploadDiscardsLateResponse() async throws {
        let state = await makeState()
        let gate = GradeGate()
        let service = GradeServiceStub(preview: try samplePreview())
        service.gate = gate
        let model = GradeImportViewModel(state: state, reader: GradeReaderStub(), service: service)
        await model.select(URL(fileURLWithPath: "/grade.xls"))
        model.startUpload()
        defer { gate.release() }
        await fulfillment(of: [gate.arrived], timeout: 3)
        model.cancelUpload()
        gate.release()
        await model.waitForUploadCompletion()
        XCTAssertNil(state.visibleGradeImport)
        XCTAssertEqual(service.callCount, 1)
    }

    @MainActor
    func testCookieRotationShowsPreviewOnlyAfterSameOwnerVerification() async throws {
        let session = GradeSessionStub(cookie: "session=alice")
        let auth = GradeAuthStub(username: "alice")
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth)
        await state.restoreSession()
        let id = try state.beginGradeImport(revision: state.authenticationRevision)
        session.save(cookie: "session=rotated")
        state.acceptGradePreview(try samplePreview(), id: id)
        XCTAssertNil(state.visibleGradeImport)
        await state.reverifyRotatedSession()
        guard let phase = state.visibleGradeImport?.phase,
              case .ready = phase else {
            return XCTFail("Same verified owner should regain their preview")
        }

        state.discardGradeImport(id: id)
        let second = try state.beginGradeImport(revision: state.authenticationRevision)
        session.save(cookie: "session=another")
        auth.username = "bob"
        state.acceptGradePreview(try samplePreview(), id: second)
        await state.reverifyRotatedSession()
        XCTAssertNil(state.visibleGradeImport)
        XCTAssertFalse(state.canAccessPrivateData)
    }

    @MainActor
    private func samplePreview() throws -> GradeImportPreview {
        try JSONDecoder().decode(GradeImportPreview.self, from: Data(previewJSON.utf8))
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    @MainActor
    private func makeState(username: String = "alice") async -> AppState {
        let state = AppState(api: MockAPIClient(), sessionStore: GradeSessionStub(cookie: "session=\(username)"),
                             authentication: GradeAuthStub(username: username))
        await state.restoreSession()
        return state
    }
}

private final class GradeAPIStub: APIClientProtocol {
    let json: String
    var paths: [String] = []
    var termIDs: [String?] = []
    var data: [Data] = []
    init(json: String) { self.json = json }
    func uploadMultipart<Value: Decodable>(path: String, file: MultipartFilePayload,
                                           termID: String?) async throws -> Value {
        paths.append(path)
        termIDs.append(termID)
        data.append(file.data)
        return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }
    func request<Value: Decodable>(_ method: String, path: String, body: Data?,
                                   preserveSessionOnPasswordError: Bool) async throws -> Value {
        throw APIError.invalidConfiguration
    }
}

@MainActor
private struct GradeReaderStub: GradeFileReading {
    func read(from url: URL) async throws -> MultipartFilePayload {
        guard let ext = MultipartFileExtension(rawValue: url.pathExtension) else { throw GradeFileError.wrongExtension }
        return try MultipartFilePayload(data: Data([1]), fileExtension: ext)
    }
}

@MainActor
private struct GradeReaderGateStub: GradeFileReading {
    let gate: GradeGate
    func read(from url: URL) async throws -> MultipartFilePayload {
        await gate.pause()
        return try MultipartFilePayload(data: Data([1]), fileExtension: .xls)
    }
}

@MainActor
private final class GradeServiceStub: GradeImportServicing {
    let previewResult: GradeImportPreview
    var error: APIError?
    var gate: GradeGate?
    private(set) var callCount = 0
    init(preview: GradeImportPreview) { previewResult = preview }
    func preview(file: MultipartFilePayload, termID: String?) async throws -> GradeImportPreview {
        callCount += 1
        await gate?.pause()
        if let error { throw error }
        return previewResult
    }
}

@MainActor
private final class GradeGate {
    let arrived = XCTestExpectation(description: "Grade upload reached gate")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func pause() async {
        arrived.fulfill()
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class GradeSessionStub: SessionStore {
    private let lock = NSLock()
    private var storedCookie: String?
    init(cookie: String?) { storedCookie = cookie }
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

private final class GradeAuthStub: AuthenticationClientProtocol {
    var username: String
    init(username: String) { self.username = username }
    func login(username: String, password: String) async throws -> (cookie: String, identity: VerifiedIdentity) {
        ("session=\(username)", VerifiedIdentity(authenticated: true, username: username))
    }
    func verify(cookie: String) async throws -> VerifiedIdentity {
        VerifiedIdentity(authenticated: true, username: username)
    }
    func logout(cookie: String) async throws {}
}

private final class GradeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

    static func register(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> String {
        let id = UUID().uuidString
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return id
    }

    static func unregister(_ id: String) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let id = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Grade-Test-ID"))
            Self.lock.lock()
            let handler = Self.handlers[id]
            Self.lock.unlock()
            let (response, data) = try XCTUnwrap(handler)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
