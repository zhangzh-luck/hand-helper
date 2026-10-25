import Combine
import Foundation
import XCTest
@testable import HandHelperNative

final class TimetableImportTests: XCTestCase {
    private let success = TimetableImportResult(termID: "2026-2027-1", coursesImported: 3,
                                                sessionsGenerated: 0, ignoredNotes: true)

    @MainActor
    func testReaderAcceptsXLSAndRejectsEmptyOversizeWrongExtensionAndMissingFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reader = ImportFileReader()
        let valid = folder.appendingPathComponent("printed.xls")
        let bytes = Data([0xD0, 0xCF, 0x11, 0xE0, 0x01])
        try bytes.write(to: valid)
        let payload = try await reader.readXLS(from: valid)
        XCTAssertEqual(payload.data, bytes)
        XCTAssertEqual(payload.safeFileName, "upload.xls")

        let exact = folder.appendingPathComponent("exact.xls")
        try Data(repeating: 0x2A, count: 2_000_000).write(to: exact)
        let exactPayload = try await reader.readXLS(from: exact)
        XCTAssertEqual(exactPayload.data.count, 2_000_000)

        let empty = folder.appendingPathComponent("empty.xls")
        try Data().write(to: empty)
        do { _ = try await reader.readXLS(from: empty); XCTFail("Expected empty file") }
        catch let error as MultipartUploadError { XCTAssertEqual(error, .emptyFile) }

        let oversized = folder.appendingPathComponent("large.xls")
        try Data(repeating: 0x2A, count: 2_000_001).write(to: oversized)
        do { _ = try await reader.readXLS(from: oversized); XCTFail("Expected size rejection") }
        catch let error as MultipartUploadError { XCTAssertEqual(error, .fileTooLarge) }

        let wrong = folder.appendingPathComponent("printed.html")
        try bytes.write(to: wrong)
        do { _ = try await reader.readXLS(from: wrong); XCTFail("Expected extension rejection") }
        catch let error as ImportFileError { XCTAssertEqual(error, .wrongExtension) }

        do { _ = try await reader.readXLS(from: folder.appendingPathComponent("missing.xls")); XCTFail("Expected read failure") }
        catch let error as ImportFileError { XCTAssertEqual(error, .unreadable) }
    }

    @MainActor
    func testServiceUsesExistingMultipartAPIAndReadOnlyEndpoints() async throws {
        let api = TimetableImportAPIStub()
        let service = TimetableImportService(api: api)
        let file = try MultipartFilePayload(data: Data([1, 2, 3]), fileExtension: .xls)
        let result = try await service.upload(file)
        XCTAssertEqual(result, success)
        XCTAssertEqual(api.uploadPaths, ["/api/v1/timetable/import-file"])
        XCTAssertEqual(api.uploadTermIDs, [nil])
        XCTAssertEqual(api.uploadData, [Data([1, 2, 3])])
        let inspection = try await service.inspect(isCurrent: { true })
        XCTAssertEqual(inspection, TimetableImportInspection(termCount: 1, sessionCount: 0))
        XCTAssertEqual(api.getPaths, ["/api/v1/terms", "/api/v1/timetable"])
    }

    @MainActor
    func testPickerCancellationAndReplacementCancellationNeverUpload() async throws {
        let state = await makeState()
        let reader = TimetableReaderStub()
        let service = TimetableServiceStub(result: success)
        let model = TimetableImportViewModel(state: state, reader: reader, service: service)
        model.selectionCancelled()
        XCTAssertEqual(service.uploadCount, 0)
        await model.select(URL(fileURLWithPath: "/printed.xls"))
        XCTAssertTrue(model.canUpload)
        // Presenting and cancelling the replacement dialog does not call startUpload().
        XCTAssertNil(state.visibleTimetableImport)
        XCTAssertEqual(service.uploadCount, 0)
    }

    @MainActor
    func testAuthenticationChangeDiscardsFileReadBeforeUpload() async throws {
        let state = await makeState()
        let gate = TimetableImportGate()
        let reader = TimetableReaderGateStub(gate: gate)
        let service = TimetableServiceStub(result: success)
        let model = TimetableImportViewModel(state: state, reader: reader, service: service)
        let selectionFinished = XCTestExpectation(description: "File selection completed")
        let selection = Task {
            await model.select(URL(fileURLWithPath: "/printed.xls"))
            selectionFinished.fulfill()
        }
        defer { gate.release() }
        await fulfillment(of: [gate.arrived], timeout: 3)
        model.authenticationDidChange()
        gate.release()
        await fulfillment(of: [selectionFinished], timeout: 3)
        selection.cancel()
        XCTAssertFalse(model.canUpload)
        XCTAssertNil(model.selectedFileName)
        XCTAssertEqual(service.uploadCount, 0)
    }

    @MainActor
    func testSuccessfulUploadPublishesMarkerAndWaitsForStrictRefreshAcknowledgement() async throws {
        let state = await makeState()
        let model = TimetableImportViewModel(state: state, reader: TimetableReaderStub(),
                                             service: TimetableServiceStub(result: success))
        await model.select(URL(fileURLWithPath: "/printed.xls"))
        model.startUpload()
        await assertUploadCompletes(model)
        let operation = try XCTUnwrap(state.visibleTimetableImport)
        guard case .refreshPending(let result, _) = operation.phase else {
            return XCTFail("Server acceptance must wait for Today strict refresh")
        }
        XCTAssertEqual(result.sessionsGenerated, 0) // Valid server result, not a failure.
        let marker = try XCTUnwrap(state.pendingCourseInvalidation(after: nil))
        XCTAssertEqual(marker.owner, "user:alice")
        // A failed strict refresh does not acknowledge the marker. A later Today
        // refresh, including after a tab switch or remount, can still observe it.
        XCTAssertEqual(state.pendingCourseInvalidation(after: nil), marker)
        state.acknowledgeCourseRefresh(marker)
        guard case .refreshCompleted(let completed)? = state.visibleTimetableImport?.phase else {
            return XCTFail("Only a completed strict refresh should finish the operation")
        }
        XCTAssertEqual(completed, success)
    }

    @MainActor
    func testSuccessfulUploadKeepsMarkerUntilStrictNetworkRefreshAndCacheWriteSucceed() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = TimetableSessionStub(cookie: "session=alice")
        let api = TimetableImportAPIStub()
        let state = AppState(api: api, sessionStore: session,
                             authentication: TimetableAuthStub(username: "alice"))
        await state.restoreSession()
        let account = VerifiedAccountContext()
        try account.confirm(username: "alice", cookie: "session=alice")
        let repository = DiskCourseRepository(api: api, session: session, account: account, directory: folder)
        let today = TodayViewModel(repository: repository,
                                   wallpaperStore: WallpaperStore(session: session, directory: folder))
        let importModel = TimetableImportViewModel(state: state, reader: TimetableReaderStub(),
                                                   service: TimetableImportService(api: api))
        await importModel.select(URL(fileURLWithPath: "/printed.xls"))
        importModel.startUpload()
        await assertUploadCompletes(importModel)
        let marker = try XCTUnwrap(state.pendingCourseInvalidation(after: nil))

        api.failPeriodRead = true
        let incomplete = await today.refreshStrict(isCurrent: {
            state.pendingCourseInvalidation(after: nil) == marker
        })
        XCTAssertFalse(incomplete.completed)
        XCTAssertEqual(state.pendingCourseInvalidation(after: nil), marker)
        XCTAssertNil(try repository.cached())

        api.failPeriodRead = false
        let complete = await today.refreshStrict(isCurrent: {
            state.pendingCourseInvalidation(after: nil) == marker
        })
        XCTAssertTrue(complete.completed)
        XCTAssertEqual(try repository.cached()?.terms.count, 1)
        XCTAssertEqual(try repository.cached()?.periods.count, 1)
        state.acknowledgeCourseRefresh(marker) // TodayView does this only after `completed`.
        guard case .refreshCompleted? = state.visibleTimetableImport?.phase else {
            return XCTFail("Successful strict refresh should acknowledge the import marker")
        }
        XCTAssertNil(state.pendingCourseInvalidation(after: marker.sequence))
    }

    @MainActor
    func testRepeatedUploadTapIsBlocked() async throws {
        let state = await makeState()
        let gate = TimetableImportGate()
        let service = TimetableServiceStub(result: success)
        service.gate = gate
        let model = TimetableImportViewModel(state: state, reader: TimetableReaderStub(), service: service)
        await model.select(URL(fileURLWithPath: "/printed.xls"))
        model.startUpload()
        model.startUpload()
        defer { gate.release() }
        await fulfillment(of: [gate.arrived], timeout: 3)
        XCTAssertEqual(service.uploadCount, 1)
        XCTAssertFalse(model.canUpload)
        gate.release()
        await assertUploadCompletes(model, gate: gate)
    }

    @MainActor
    func testTimeoutOfflineAndServer500RemainUnconfirmedWithoutAutomaticPostRetry() async throws {
        for failure in [APIError.timeout, .connection, .server(status: 500, message: "server error")] {
            let state = await makeState()
            let service = TimetableServiceStub(result: success)
            service.uploadError = failure
            let model = TimetableImportViewModel(state: state, reader: TimetableReaderStub(), service: service)
            await model.select(URL(fileURLWithPath: "/printed.xls"))
            model.startUpload()
            await assertUploadCompletes(model)
            guard let phase = state.visibleTimetableImport?.phase,
                  case .unconfirmed = phase else {
                return XCTFail("\(failure) must be treated as unknown server outcome")
            }
            await model.inspectUnconfirmed()
            XCTAssertEqual(service.uploadCount, 1)
            XCTAssertEqual(service.inspectCount, 1)
            XCTAssertEqual(state.visibleTimetableImport?.inspection?.termCount, 1)
            XCTAssertNotNil(state.pendingCourseInvalidation(after: nil),
                            "Unknown server outcome may have changed course data")
        }
    }

    @MainActor
    func test422MayHaveChangedCoursesAndNeverClaimsImportSuccess() async throws {
        let state = await makeState()
        let service = TimetableServiceStub(result: success)
        service.uploadError = APIError.server(status: 422, message: "rebuild rejected")
        let model = TimetableImportViewModel(state: state, reader: TimetableReaderStub(), service: service)
        await model.select(URL(fileURLWithPath: "/printed.xls"))
        model.startUpload()
        await assertUploadCompletes(model)
        let operation = try XCTUnwrap(state.visibleTimetableImport)
        guard case .unconfirmed(let message) = operation.phase else {
            return XCTFail("422 after POST cannot prove that course replacement rolled back")
        }
        XCTAssertTrue(message.contains("尚不明确"))
        let marker = try XCTUnwrap(state.pendingCourseInvalidation(after: nil))
        await model.inspectUnconfirmed()
        XCTAssertEqual(service.uploadCount, 1)
        XCTAssertEqual(service.inspectCount, 1)
        guard let phase = state.visibleTimetableImport?.phase, case .unconfirmed = phase else {
            return XCTFail("Read-only GET cannot confirm this particular POST")
        }
        state.acknowledgeCourseRefresh(marker)
        guard let refreshedPhase = state.visibleTimetableImport?.phase,
              case .unconfirmed = refreshedPhase else {
            return XCTFail("Course refresh cannot confirm the import transaction")
        }
    }

    @MainActor
    func test401RevokesIdentityAndLocalValidationFailureDoesNotRefresh() async throws {
        let expiredState = await makeState()
        let expiredService = TimetableServiceStub(result: success)
        expiredService.uploadError = APIError.unauthorized(message: "expired")
        let expiredModel = TimetableImportViewModel(state: expiredState, reader: TimetableReaderStub(),
                                                    service: expiredService)
        await expiredModel.select(URL(fileURLWithPath: "/printed.xls"))
        expiredModel.startUpload()
        await assertUploadCompletes(expiredModel)
        XCTAssertNil(expiredState.pendingCourseInvalidation(after: nil))
        XCTAssertNil(expiredState.visibleTimetableImport)
        XCTAssertFalse(expiredState.canAccessPrivateData)

        let localState = await makeState()
        let localService = TimetableServiceStub(result: success)
        localService.uploadError = MultipartUploadError.fileTooLarge
        let localModel = TimetableImportViewModel(state: localState, reader: TimetableReaderStub(),
                                                  service: localService)
        await localModel.select(URL(fileURLWithPath: "/printed.xls"))
        localModel.startUpload()
        await assertUploadCompletes(localModel)
        XCTAssertNil(localState.pendingCourseInvalidation(after: nil))
        XCTAssertNil(localState.visibleTimetableImport)
        XCTAssertNotNil(localModel.errorMessage)
    }

    @MainActor
    func testExplicitCancellationAndLateResponseRemainUnconfirmed() async throws {
        let state = await makeState()
        let gate = TimetableImportGate()
        let service = TimetableServiceStub(result: success)
        service.gate = gate
        let model = TimetableImportViewModel(state: state, reader: TimetableReaderStub(), service: service)
        await model.select(URL(fileURLWithPath: "/printed.xls"))
        model.startUpload()
        defer { gate.release() }
        await fulfillment(of: [gate.arrived], timeout: 3)
        model.cancelUpload()
        gate.release() // The mock returns success even after cancellation.
        await assertUploadCompletes(model, gate: gate)
        guard let phase = state.visibleTimetableImport?.phase,
              case .unconfirmed = phase else {
            return XCTFail("Cancellation cannot prove that the server rolled back")
        }
        XCTAssertNotNil(state.pendingCourseInvalidation(after: nil),
                        "The server may have committed before cancellation")
        XCTAssertEqual(service.uploadCount, 1)
    }

    @MainActor
    func testLogoutDuringUploadDiscardsLateSuccess() async throws {
        let state = await makeState()
        let gate = TimetableImportGate()
        let service = TimetableServiceStub(result: success)
        service.gate = gate
        let model = TimetableImportViewModel(state: state, reader: TimetableReaderStub(), service: service)
        await model.select(URL(fileURLWithPath: "/printed.xls"))
        model.startUpload()
        defer { gate.release() }
        await fulfillment(of: [gate.arrived], timeout: 3)
        await state.logout()
        gate.release() // Simulate a server response arriving after local sign-out.
        await assertUploadCompletes(model, gate: gate)
        XCTAssertNil(state.pendingTimetableImport)
        XCTAssertNil(state.pendingCourseInvalidation(after: nil))
        XCTAssertFalse(state.canAccessPrivateData)
    }

    @MainActor
    func testAcceptedResultCannotBeDemotedByLateFailureOrDuplicated() async throws {
        let state = await makeState()
        let id = try state.beginTimetableImport(revision: state.authenticationRevision)
        state.acceptTimetableImport(success, id: id)
        let marker = try XCTUnwrap(state.pendingCourseInvalidation(after: nil))
        state.markTimetableImportUnconfirmed("late failure", id: id)
        state.acceptTimetableImport(success, id: id)
        XCTAssertEqual(state.pendingCourseInvalidation(after: nil), marker)
        guard let phase = state.visibleTimetableImport?.phase,
              case .refreshPending = phase else {
            return XCTFail("A stale callback must not replace a confirmed server result")
        }
    }

    @MainActor
    func testLogoutAndAccountSwitchDiscardLateResult() async throws {
        let state = await makeState()
        let model = TimetableImportViewModel(state: state, reader: TimetableReaderStub(),
                                             service: TimetableServiceStub(result: success))
        await model.select(URL(fileURLWithPath: "/printed.xls"))
        XCTAssertTrue(model.canUpload)
        let revision = state.authenticationRevision
        let id = try state.beginTimetableImport(revision: revision)
        await state.logout()
        XCTAssertFalse(model.canUpload, "A's selected file cannot be uploaded under another revision")
        state.acceptTimetableImport(success, id: id)
        XCTAssertNil(state.pendingTimetableImport)
        XCTAssertNil(state.pendingCourseInvalidation(after: nil))
        XCTAssertFalse(state.canAccessPrivateData)

        // A new verified account cannot adopt an old operation ticket.
        let session = state.sessionStore
        session.save(cookie: "session=bob")
        let other = TimetableAuthStub(username: "bob")
        let otherState = AppState(api: MockAPIClient(), sessionStore: session, authentication: other)
        await otherState.restoreSession()
        XCTAssertEqual(try otherState.requireCurrentAccount(revision: otherState.authenticationRevision),
                       "user:bob")
        otherState.acceptTimetableImport(success, id: id)
        XCTAssertNil(otherState.pendingCourseInvalidation(after: nil))
    }

    @MainActor
    func testCookieRotationSameOwnerRecoversAcceptedUploadDifferentOwnerRejectsIt() async throws {
        let session = TimetableSessionStub(cookie: "session=alice")
        let auth = TimetableAuthStub(username: "alice")
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth)
        await state.restoreSession()
        let id = try state.beginTimetableImport(revision: state.authenticationRevision)
        session.save(cookie: "session=rotated")
        state.acceptTimetableImport(success, id: id)
        XCTAssertNil(state.pendingCourseInvalidation(after: nil))
        await state.reverifyRotatedSession()
        XCTAssertEqual(state.pendingCourseInvalidation(after: nil)?.owner, "user:alice")
        guard let phase = state.visibleTimetableImport?.phase,
              case .refreshPending = phase else {
            return XCTFail("Same verified owner should resume the successful import")
        }

        let otherSession = TimetableSessionStub(cookie: "session=alice")
        let otherAuth = TimetableAuthStub(username: "alice")
        let otherState = AppState(api: MockAPIClient(), sessionStore: otherSession,
                                  authentication: otherAuth)
        await otherState.restoreSession()
        let second = try otherState.beginTimetableImport(revision: otherState.authenticationRevision)
        otherSession.save(cookie: "session=another")
        otherAuth.username = "bob"
        otherState.acceptTimetableImport(success, id: second)
        await otherState.reverifyRotatedSession()
        XCTAssertFalse(otherState.canAccessPrivateData)
        XCTAssertNil(otherState.pendingTimetableImport)
    }

    @MainActor
    func testUnknownUploadDuringCookieRotationRefreshesOnlyAfterSameOwnerVerification() async throws {
        let session = TimetableSessionStub(cookie: "session=alice")
        let state = AppState(api: MockAPIClient(), sessionStore: session,
                             authentication: TimetableAuthStub(username: "alice"))
        await state.restoreSession()
        let id = try state.beginTimetableImport(revision: state.authenticationRevision)
        session.save(cookie: "session=rotated")
        state.markTimetableImportUnconfirmed("HTTP 422: outcome unknown", id: id)
        XCTAssertNil(state.pendingCourseInvalidation(after: nil))
        await state.reverifyRotatedSession()
        XCTAssertEqual(state.pendingCourseInvalidation(after: nil)?.owner, "user:alice")
        guard let phase = state.visibleTimetableImport?.phase, case .unconfirmed = phase else {
            return XCTFail("Refreshing data cannot promote an unknown import to success")
        }
    }

    @MainActor
    func testUploadSetCookieEventReverifiesBeforePublishingCourseInvalidation() async throws {
        let session = TimetableSessionStub(cookie: "session=alice")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimetableRotationURLProtocol.self]
        let testID = TimetableRotationURLProtocol.register { request in
            XCTAssertEqual(request.url?.path, "/api/v1/timetable/import-file")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=alice")
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Set-Cookie": "session=rotated; Path=/"]
            ))
            let body = #"{"success":true,"data":{"term_id":"2026-2027-1","courses_imported":3,"sessions_generated":0,"ignored_notes":true}}"#
            return (response, Data(body.utf8))
        }
        defer { TimetableRotationURLProtocol.unregister(testID) }
        configuration.httpAdditionalHeaders = ["X-Timetable-Test-ID": testID]
        let client = APIClient(configuration: .development, sessionStore: session,
                               session: URLSession(configuration: configuration))
        let state = AppState(api: client, sessionStore: session,
                             authentication: TimetableAuthStub(username: "alice"))
        await state.restoreSession()
        let initialRevision = state.authenticationRevision
        let published = XCTestExpectation(description: "Verified rotated account published refresh")
        published.assertForOverFulfill = false
        let subscription = state.$courseDataInvalidation.sink { marker in
            if marker?.owner == "user:alice", let revision = marker?.authenticationRevision,
               revision > initialRevision {
                published.fulfill()
            }
        }
        defer { subscription.cancel() }
        let model = TimetableImportViewModel(state: state, reader: TimetableReaderStub(),
                                             service: TimetableImportService(api: client))
        await model.select(URL(fileURLWithPath: "/printed.xls"))
        model.startUpload()
        await assertUploadCompletes(model)
        await fulfillment(of: [published], timeout: 3)
        XCTAssertEqual(session.cookie, "session=rotated")
        XCTAssertTrue(state.canAccessPrivateData)
        XCTAssertEqual(state.pendingCourseInvalidation(after: nil)?.owner, "user:alice")
        guard let phase = state.visibleTimetableImport?.phase, case .refreshPending = phase else {
            return XCTFail("Successful response should survive Set-Cookie re-verification")
        }
    }

    @MainActor
    func testReadOnlyInspectionFailureKeepsUnknownResult() async throws {
        let state = await makeState()
        let service = TimetableServiceStub(result: success)
        service.uploadError = APIError.timeout
        service.inspectError = .connection
        let model = TimetableImportViewModel(state: state, reader: TimetableReaderStub(), service: service)
        await model.select(URL(fileURLWithPath: "/printed.xls"))
        model.startUpload()
        await assertUploadCompletes(model)
        await model.inspectUnconfirmed()
        guard let phase = state.visibleTimetableImport?.phase,
              case .unconfirmed = phase else {
            return XCTFail("Failed GET must not turn an unknown POST into success")
        }
        XCTAssertEqual(service.uploadCount, 1)
        XCTAssertEqual(service.inspectCount, 1)
    }

    @MainActor
    func testCookieReverification401DiscardsAcceptedImport() async throws {
        let session = TimetableSessionStub(cookie: "session=alice")
        let auth = TimetableAuthStub(username: "alice")
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth)
        await state.restoreSession()
        let id = try state.beginTimetableImport(revision: state.authenticationRevision)
        session.save(cookie: "session=rotated")
        state.acceptTimetableImport(success, id: id)
        auth.verificationError = .unauthorized(message: "expired")
        await state.reverifyRotatedSession()
        XCTAssertNil(state.pendingTimetableImport)
        XCTAssertNil(state.pendingCourseInvalidation(after: nil))
        XCTAssertFalse(state.canAccessPrivateData)
    }

    @MainActor
    private func assertUploadCompletes(_ model: TimetableImportViewModel,
                                       gate: TimetableImportGate? = nil) async {
        let completion = XCTestExpectation(description: "Upload task completed")
        var finished = false
        let waiter = Task {
            await model.waitForUploadCompletion()
            finished = true
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 3)
        if !finished {
            gate?.release()
            model.cancelUpload()
            waiter.cancel()
        }
    }

    @MainActor
    private func makeState() async -> AppState {
        let session = TimetableSessionStub(cookie: "session=alice")
        let state = AppState(api: MockAPIClient(), sessionStore: session,
                             authentication: TimetableAuthStub(username: "alice"))
        await state.restoreSession()
        return state
    }
}

private final class TimetableImportAPIStub: APIClientProtocol {
    var uploadPaths: [String] = []
    var uploadTermIDs: [String?] = []
    var uploadData: [Data] = []
    var getPaths: [String] = []
    var failPeriodRead = false

    func uploadMultipart<Value: Decodable>(path: String, file: MultipartFilePayload,
                                           termID: String?) async throws -> Value {
        uploadPaths.append(path)
        uploadTermIDs.append(termID)
        uploadData.append(file.data)
        return try JSONDecoder().decode(Value.self, from: Data(
            #"{"term_id":"2026-2027-1","courses_imported":3,"sessions_generated":0,"ignored_notes":true}"#.utf8))
    }

    func request<Value: Decodable>(_ method: String, path: String, body: Data?,
                                   preserveSessionOnPasswordError: Bool) async throws -> Value {
        XCTAssertEqual(method, "GET")
        getPaths.append(path)
        if path == "/api/v1/settings/period-times", failPeriodRead { throw APIError.connection }
        let json: String
        switch path {
        case "/api/v1/auth/me": json = #"{"username":"alice"}"#
        case "/api/v1/terms":
            json = #"[{"id":1,"source_term_id":"2026-2027-1","display_name":"秋季","start_date":null,"is_current":true}]"#
        case "/api/v1/settings/period-times":
            json = #"[{"period_number":1,"start_time":"08:00","end_time":"08:45"}]"#
        default: json = "[]"
        }
        return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }
}

@MainActor
private struct TimetableReaderStub: ImportFileReading {
    func readXLS(from url: URL) async throws -> MultipartFilePayload {
        try MultipartFilePayload(data: Data([1]), fileExtension: .xls)
    }
}

@MainActor
private struct TimetableReaderGateStub: ImportFileReading {
    let gate: TimetableImportGate
    func readXLS(from url: URL) async throws -> MultipartFilePayload {
        await gate.pause()
        return try MultipartFilePayload(data: Data([1]), fileExtension: .xls)
    }
}

@MainActor
private final class TimetableServiceStub: TimetableImportServicing {
    let result: TimetableImportResult
    var uploadError: Error?
    var inspectError: APIError?
    var gate: TimetableImportGate?
    private(set) var uploadCount = 0
    private(set) var inspectCount = 0

    init(result: TimetableImportResult) { self.result = result }
    func upload(_ file: MultipartFilePayload) async throws -> TimetableImportResult {
        uploadCount += 1
        await gate?.pause()
        if let uploadError { throw uploadError }
        return result
    }
    func inspect(isCurrent: @escaping @MainActor () -> Bool) async throws -> TimetableImportInspection {
        inspectCount += 1
        if let inspectError { throw inspectError }
        guard isCurrent() else { throw MultipartUploadError.sessionChanged }
        return TimetableImportInspection(termCount: 1, sessionCount: 2)
    }
}

@MainActor
private final class TimetableImportGate {
    let arrived = XCTestExpectation(description: "Upload reached gate")
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

private final class TimetableSessionStub: SessionStore {
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

private final class TimetableRotationURLProtocol: URLProtocol {
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
            let id = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Timetable-Test-ID"))
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

private final class TimetableAuthStub: AuthenticationClientProtocol {
    var username: String
    var verificationError: APIError?
    init(username: String) { self.username = username }
    func login(username: String, password: String) async throws -> (cookie: String, identity: VerifiedIdentity) {
        ("session=\(username)", VerifiedIdentity(authenticated: true, username: username))
    }
    func verify(cookie: String) async throws -> VerifiedIdentity {
        if let verificationError { throw verificationError }
        return VerifiedIdentity(authenticated: true, username: username)
    }
    func logout(cookie: String) async throws {}
}
