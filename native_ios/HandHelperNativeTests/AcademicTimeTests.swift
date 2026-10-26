import Foundation
import XCTest
@testable import HandHelperNative

final class AcademicTimeTests: XCTestCase {
    private let termJSON = #"{"id":8,"source_term_id":"2026-2027-1","display_name":"秋季","start_date":"2026-08-31","is_current":true}"#
    private let periodJSON = #"{"period_number":1,"start_time":"08:30","end_time":"09:15"}"#

    func testMondayAndPeriodValidation() {
        let monday = AcademicTimeValidation.date("2026-08-31")!
        let tuesday = AcademicTimeValidation.date("2026-09-01")!
        XCTAssertTrue(AcademicTimeValidation.isMonday(monday))
        XCTAssertFalse(AcademicTimeValidation.isMonday(tuesday))
        XCTAssertEqual(AcademicTimeValidation.dateString(monday), "2026-08-31")
        XCTAssertTrue(AcademicTimeValidation.validPeriod(start: "08:30", end: "09:15"))
        XCTAssertFalse(AcademicTimeValidation.validPeriod(start: "09:15", end: "08:30"))
        XCTAssertFalse(AcademicTimeValidation.validPeriod(start: "09:15", end: "09:15"))
        XCTAssertFalse(AcademicTimeValidation.validPeriod(start: "25:00", end: "26:00"))
    }

    @MainActor
    func testBothWritesUseRealPathsFieldsAndReadBack() async throws {
        let api = AcademicTimeAPIStub()
        api.responder = { method, path, _ in
            switch (method, path) {
            case ("PUT", "/api/v1/terms/8/start-date"),
                 ("PUT", "/api/v1/settings/period-times/1"):
                return Data(#"{"sessions_generated":18}"#.utf8)
            case ("GET", "/api/v1/terms"):
                return Data("[{\"id\":8,\"source_term_id\":\"2026-2027-1\",\"display_name\":\"秋季\",\"start_date\":\"2026-09-07\",\"is_current\":true}]".utf8)
            case ("GET", "/api/v1/settings/period-times"):
                return Data(#"[{"period_number":1,"start_time":"08:40","end_time":"09:20"}]"#.utf8)
            default: throw APIError.invalidResponse
            }
        }
        let service = AcademicTimeService(api: api)
        let termResult = try await service.saveTerm(id: 8, startDate: "2026-09-07")
        XCTAssertEqual(termResult, .confirmed(sessionsGenerated: 18))
        let periodResult = try await service.savePeriod(number: 1, start: "08:40", end: "09:20")
        XCTAssertEqual(periodResult, .confirmed(sessionsGenerated: 18))
        XCTAssertEqual(api.requests.map { "\($0.method) \($0.path)" }, [
            "PUT /api/v1/terms/8/start-date", "GET /api/v1/terms",
            "PUT /api/v1/settings/period-times/1", "GET /api/v1/settings/period-times"
        ])
        let termBody = try XCTUnwrap(api.requests[0].body)
        let periodBody = try XCTUnwrap(api.requests[2].body)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: termBody) as? [String: String],
                       ["start_date": "2026-09-07"])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: periodBody) as? [String: String],
                       ["start_time": "08:40", "end_time": "09:20"])
    }

    @MainActor
    func testPutSuccessButReadBackFailureIsNotConfirmed() async throws {
        let api = AcademicTimeAPIStub()
        api.responder = { method, _, _ in
            if method == "PUT" { return Data(#"{"sessions_generated":7}"#.utf8) }
            throw APIError.connection
        }
        let result = try await AcademicTimeService(api: api).saveTerm(id: 8, startDate: "2026-09-07")
        XCTAssertEqual(result, .unconfirmed)
    }

    @MainActor
    func testReadBackMismatchIsNotConfirmed() async throws {
        let api = AcademicTimeAPIStub()
        api.responder = { method, _, _ in
            if method == "PUT" { return Data(#"{"sessions_generated":7}"#.utf8) }
            return Data("[\(self.termJSON)]".utf8)
        }
        let outcome = try await AcademicTimeService(api: api).saveTerm(id: 8, startDate: "2026-09-07")
        XCTAssertEqual(outcome, .unconfirmed)
    }

    @MainActor
    func testServer422UnauthorizedTimeoutAndOffline() async {
        for failure in [
            APIError.server(status: 422, message: "学期第一周日期必须是星期一"),
            APIError.unauthorized(message: "登录状态已失效"),
            APIError.timeout, APIError.connection
        ] {
            let api = AcademicTimeAPIStub()
            api.responder = { _, _, _ in throw failure }
            do {
                _ = try await AcademicTimeService(api: api).saveTerm(id: 8, startDate: "2026-09-07")
                XCTFail("Expected \(failure)")
            } catch let error as APIError {
                XCTAssertEqual(error, failure)
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    @MainActor
    func testConfirmedWritePublishesAccountBoundPendingRefreshAcrossTabsAndRemount() async throws {
        let api = AcademicTimeAPIStub()
        api.responder = { method, path, _ in
            if method == "PUT" { return Data(#"{"sessions_generated":4}"#.utf8) }
            if path == "/api/v1/terms" {
                let saved = api.requests.contains { $0.method == "PUT" }
                let date = saved ? "2026-09-07" : "2026-08-31"
                return Data("[{\"id\":8,\"source_term_id\":\"2026-2027-1\",\"display_name\":\"秋季\",\"start_date\":\"\(date)\",\"is_current\":true}]".utf8)
            }
            if path == "/api/v1/settings/period-times" { return Data("[\(self.periodJSON)]".utf8) }
            throw APIError.invalidResponse
        }
        let session = AcademicTimeSessionStore()
        session.save(cookie: "session=alice")
        let state = AppState(api: api, sessionStore: session, authentication: AcademicTimeAuth())
        await state.restoreSession()
        let model = AcademicTimeViewModel(state: state, service: AcademicTimeService(api: api))
        await model.load()
        model.firstMonday = try XCTUnwrap(AcademicTimeValidation.date("2026-09-07"))
        state.selectedTab = .settings
        await model.saveTerm()
        let marker = try XCTUnwrap(state.pendingCourseInvalidation(after: nil))
        XCTAssertEqual(marker.owner, "user:alice")
        XCTAssertNotNil(state.pendingCourseInvalidation(after: nil)) // A newly mounted Today page still sees it.
        state.selectedTab = .today
        XCTAssertEqual(state.pendingCourseInvalidation(after: nil), marker)
        XCTAssertNil(state.pendingCourseInvalidation(after: marker.sequence))
        await state.logout()
        XCTAssertNil(state.pendingCourseInvalidation(after: nil))
        await state.login(username: "bob", password: "fixture")
        XCTAssertNil(state.pendingCourseInvalidation(after: nil))
    }

    @MainActor
    func testSavePreventsDuplicateSubmission() async throws {
        let api = AcademicTimeAPIStub()
        let gate = AcademicTimeGate()
        api.putGate = gate
        api.responder = { method, path, _ in
            if method == "PUT" {
                await api.putGate?.pause()
                return Data(#"{"sessions_generated":4}"#.utf8)
            }
            if path == "/api/v1/terms" {
                let saved = api.requests.contains { $0.method == "PUT" }
                let date = saved ? "2026-09-07" : "2026-08-31"
                return Data("[{\"id\":8,\"source_term_id\":\"2026-2027-1\",\"display_name\":\"秋季\",\"start_date\":\"\(date)\",\"is_current\":true}]".utf8)
            }
            return Data("[\(self.periodJSON)]".utf8)
        }
        let session = AcademicTimeSessionStore()
        session.save(cookie: "session=alice")
        let state = AppState(api: api, sessionStore: session, authentication: AcademicTimeAuth())
        await state.restoreSession()
        let model = AcademicTimeViewModel(state: state, service: AcademicTimeService(api: api))
        await model.load()
        model.firstMonday = try XCTUnwrap(AcademicTimeValidation.date("2026-09-07"))
        let pending = Task { await model.saveTerm() }
        defer { gate.release(); pending.cancel() }
        await fulfillment(of: [gate.arrived], timeout: 3)
        guard gate.didArrive else { return }
        await model.saveTerm()
        XCTAssertEqual(api.requests.filter { $0.method == "PUT" }.count, 1)
        gate.release()
        await pending.value
        XCTAssertNotNil(state.pendingCourseInvalidation(after: nil))
    }

    @MainActor
    func testLatePutAfterAccountSwitchCannotPublishInvalidation() async throws {
        let api = AcademicTimeAPIStub()
        let gate = AcademicTimeGate()
        api.putGate = gate
        api.responder = { method, path, _ in
            if method == "PUT" {
                await api.putGate?.pause()
                return Data(#"{"sessions_generated":4}"#.utf8)
            }
            if path == "/api/v1/terms" { return Data("[\(self.termJSON)]".utf8) }
            return Data("[\(self.periodJSON)]".utf8)
        }
        let session = AcademicTimeSessionStore()
        session.save(cookie: "session=alice")
        let state = AppState(api: api, sessionStore: session, authentication: AcademicTimeAuth())
        await state.restoreSession()
        let model = AcademicTimeViewModel(state: state, service: AcademicTimeService(api: api))
        await model.load()
        model.firstMonday = try XCTUnwrap(AcademicTimeValidation.date("2026-09-07"))
        let pending = Task { await model.saveTerm() }
        defer { gate.release(); pending.cancel() }
        await fulfillment(of: [gate.arrived], timeout: 3)
        guard gate.didArrive else { return }
        await state.logout()
        model.reset() // Mirrors AcademicTimeView authenticationRevision handling.
        await state.login(username: "bob", password: "fixture")
        gate.release()
        await pending.value
        XCTAssertNil(state.pendingCourseInvalidation(after: nil))
        XCTAssertNil(model.statusMessage)
        XCTAssertFalse(model.isSaving)
    }
    @MainActor
    func testUnconfirmedWriteDoesNotNotifyToday() async throws {
        let api = AcademicTimeAPIStub()
        var termReads = 0
        api.responder = { method, path, _ in
            if method == "PUT" { return Data(#"{"sessions_generated":4}"#.utf8) }
            if path == "/api/v1/terms" {
                termReads += 1
                if termReads > 1 { throw APIError.connection }
                return Data("[\(self.termJSON)]".utf8)
            }
            return Data("[\(self.periodJSON)]".utf8)
        }
        let session = AcademicTimeSessionStore()
        session.save(cookie: "session=alice")
        let state = AppState(api: api, sessionStore: session, authentication: AcademicTimeAuth())
        await state.restoreSession()
        let model = AcademicTimeViewModel(state: state, service: AcademicTimeService(api: api))
        await model.load()
        model.firstMonday = try XCTUnwrap(AcademicTimeValidation.date("2026-09-07"))
        await model.saveTerm()
        XCTAssertNil(state.pendingCourseInvalidation(after: nil))
        XCTAssertNotNil(model.statusMessage)
        XCTAssertNil(model.errorMessage)
    }
    @MainActor
    func testStrictRefreshRequiresAllThreeResourcesBeforeReplacingSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = AcademicTimeSessionStore()
        session.save(cookie: "session=alice")
        let account = VerifiedAccountContext()
        try account.confirm(username: "alice", cookie: "session=alice")
        let api = AcademicTimeAPIStub()
        api.responder = { _, path, _ in
            switch path {
            case "/api/v1/auth/me": return Data(#"{"username":"alice"}"#.utf8)
            case "/api/v1/timetable": return Data("[]".utf8)
            case "/api/v1/terms": return Data("[\(self.termJSON)]".utf8)
            case "/api/v1/settings/period-times": throw APIError.connection
            default: return Data("[]".utf8)
            }
        }
        let repository = DiskCourseRepository(api: api, session: session, account: account, directory: folder)
        do {
            _ = try await repository.refreshStrict(on: Date(), isCurrent: { true })
            XCTFail("Strict refresh must fail if periods fail")
        } catch let error as APIError { XCTAssertEqual(error, .connection) }
        XCTAssertNil(try repository.cached())
        let today = TodayViewModel(repository: repository,
                                   wallpaperStore: WallpaperStore(session: session, account: account, directory: folder))
        today.load()
        let incomplete = await today.refreshStrict(isCurrent: { true })
        XCTAssertFalse(incomplete.completed)
        XCTAssertNil(today.snapshot)
        api.responder = { _, path, _ in
            switch path {
            case "/api/v1/auth/me": return Data(#"{"username":"alice"}"#.utf8)
            case "/api/v1/timetable": return Data("[]".utf8)
            case "/api/v1/terms": return Data("[\(self.termJSON)]".utf8)
            case "/api/v1/settings/period-times": return Data("[\(self.periodJSON)]".utf8)
            default: return Data("[]".utf8)
            }
        }
        let fresh = try await repository.refreshStrict(on: Date(), isCurrent: { true })
        XCTAssertEqual(fresh.terms.count, 1)
        XCTAssertEqual(fresh.periods.count, 1)
        XCTAssertEqual(try repository.cached()?.terms, fresh.terms)
        XCTAssertEqual(try repository.cached()?.periods, fresh.periods)
        let complete = await today.refreshStrict(isCurrent: { true })
        XCTAssertTrue(complete.completed)
        XCTAssertEqual(today.snapshot?.terms, fresh.terms)
        XCTAssertEqual(today.snapshot?.periods, fresh.periods)
    }

    @MainActor
    func testOldRefreshCannotWriteAfterAccountSwitch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = AcademicTimeSessionStore()
        session.save(cookie: "session=alice")
        let account = VerifiedAccountContext()
        try account.confirm(username: "alice", cookie: "session=alice")
        let api = AcademicTimeAPIStub()
        let gate = AcademicTimeGate()
        api.timetableGate = gate
        api.responder = { _, path, _ in
            if path == "/api/v1/auth/me" { return Data(#"{"username":"alice"}"#.utf8) }
            if path == "/api/v1/timetable" {
                await api.timetableGate?.pause()
                return Data("[]".utf8)
            }
            return Data("[]".utf8)
        }
        let repository = DiskCourseRepository(api: api, session: session, account: account, directory: folder)
        let pending = Task { try await repository.refreshStrict(on: Date(), isCurrent: {
            session.cookie == "session=alice" && account.owner == "user:alice"
        }) }
        defer { gate.release(); pending.cancel() }
        await fulfillment(of: [gate.arrived], timeout: 3)
        guard gate.didArrive else { return }
        account.clear()
        session.save(cookie: "session=bob")
        try account.confirm(username: "bob", cookie: "session=bob")
        gate.release()
        do { _ = try await pending.value; XCTFail("Old response must be rejected") }
        catch {
            XCTAssertNil(try repository.cached())
            account.clear()
            session.save(cookie: "session=alice")
            try account.confirm(username: "alice", cookie: "session=alice")
            XCTAssertNil(try repository.cached(), "Delayed Alice refresh must not write her cache")
        }
    }
    @MainActor
    func testPendingWriteSurvivesPageReentryAndRecheckUsesOnlyGet() async throws {
        let api = AcademicTimeAPIStub()
        var offline = true
        api.responder = { method, path, _ in
            if method == "PUT" { return Data(#"{"sessions_generated":4}"#.utf8) }
            if path == "/api/v1/terms" {
                let wrote = api.requests.contains { $0.method == "PUT" }
                if wrote && offline { throw APIError.connection }
                let date = wrote ? "2026-09-07" : "2026-08-31"
                return Data("[\(self.termJSON.replacingOccurrences(of: "2026-08-31", with: date))]".utf8)
            }
            return Data("[\(self.periodJSON)]".utf8)
        }
        let session = AcademicTimeSessionStore()
        session.save(cookie: "session=alice")
        let state = AppState(api: api, sessionStore: session, authentication: AcademicTimeAuth())
        await state.restoreSession()
        let model = AcademicTimeViewModel(state: state, service: AcademicTimeService(api: api))
        await model.load()
        model.firstMonday = try XCTUnwrap(AcademicTimeValidation.date("2026-09-07"))
        await model.saveTerm()
        XCTAssertEqual(state.visiblePendingAcademicTimeWrites.count, 1)
        XCTAssertNil(state.pendingCourseInvalidation(after: nil))
        offline = false
        let reopened = AcademicTimeViewModel(state: state, service: AcademicTimeService(api: api))
        await reopened.load()
        XCTAssertEqual(state.visiblePendingAcademicTimeWrites.count, 1)
        await state.reconcilePendingAcademicTimeWrites()
        XCTAssertTrue(state.visiblePendingAcademicTimeWrites.isEmpty)
        XCTAssertEqual(state.pendingCourseInvalidation(after: nil)?.owner, "user:alice")
        XCTAssertEqual(api.requests.filter { $0.method == "PUT" }.count, 1)
    }

    @MainActor
    func testMismatchedAndFailedRecheckRemainPending() async throws {
        let api = AcademicTimeAPIStub()
        var offline = false
        api.responder = { method, path, _ in
            if method == "PUT" { return Data(#"{"sessions_generated":4}"#.utf8) }
            if path == "/api/v1/terms" {
                if offline { throw APIError.connection }
                let date = api.requests.filter { $0.method == "PUT" }.count >= 2 ? "2026-09-14" : "2026-08-31"
                return Data("[\(self.termJSON.replacingOccurrences(of: "2026-08-31", with: date))]".utf8)
            }
            return Data("[\(self.periodJSON)]".utf8)
        }
        let session = AcademicTimeSessionStore()
        session.save(cookie: "session=alice")
        let state = AppState(api: api, sessionStore: session, authentication: AcademicTimeAuth())
        await state.restoreSession()
        let model = AcademicTimeViewModel(state: state, service: AcademicTimeService(api: api))
        await model.load()
        model.firstMonday = try XCTUnwrap(AcademicTimeValidation.date("2026-09-07"))
        await model.saveTerm()
        XCTAssertEqual(state.visiblePendingAcademicTimeWrites.count, 1)
        XCTAssertNil(state.pendingCourseInvalidation(after: nil))
        offline = true
        await state.reconcilePendingAcademicTimeWrites()
        XCTAssertEqual(state.visiblePendingAcademicTimeWrites.count, 1)
        XCTAssertNotNil(state.visiblePendingAcademicTimeWrites.first?.message)
        XCTAssertEqual(api.requests.filter { $0.method == "PUT" }.count, 1)
        offline = false
        model.firstMonday = try XCTUnwrap(AcademicTimeValidation.date("2026-09-14"))
        await model.saveTerm()
        XCTAssertTrue(state.visiblePendingAcademicTimeWrites.isEmpty)
        XCTAssertNotNil(state.pendingCourseInvalidation(after: nil))
        XCTAssertEqual(api.requests.filter { $0.method == "PUT" }.count, 2)
    }

    @MainActor
    func testRotationToSameOwnerRechecksAcceptedWriteUnderNewRevision() async throws {
        let api = AcademicTimeAPIStub()
        let gate = AcademicTimeGate()
        api.putGate = gate
        api.responder = { method, path, _ in
            if method == "PUT" { await gate.pause(); return Data(#"{"sessions_generated":4}"#.utf8) }
            if path == "/api/v1/terms" {
                let date = api.requests.contains { $0.method == "PUT" } ? "2026-09-07" : "2026-08-31"
                return Data("[\(self.termJSON.replacingOccurrences(of: "2026-08-31", with: date))]".utf8)
            }
            return Data("[\(self.periodJSON)]".utf8)
        }
        let session = AcademicTimeSessionStore()
        session.save(cookie: "session=alice")
        let state = AppState(api: api, sessionStore: session, authentication: AcademicTimeAuth())
        await state.restoreSession()
        let model = AcademicTimeViewModel(state: state, service: AcademicTimeService(api: api))
        await model.load()
        model.firstMonday = try XCTUnwrap(AcademicTimeValidation.date("2026-09-07"))
        let revision = state.authenticationRevision
        let pending = Task { await model.saveTerm() }
        defer { gate.release(); pending.cancel() }
        await fulfillment(of: [gate.arrived], timeout: 3)
        guard gate.didArrive else { return }
        session.save(cookie: "session=rotated")
        await state.reverifyRotatedSession()
        XCTAssertGreaterThan(state.authenticationRevision, revision)
        XCTAssertNil(state.pendingCourseInvalidation(after: nil))
        gate.release()
        await pending.value
        XCTAssertTrue(state.pendingAcademicTimeWrites.isEmpty)
        XCTAssertEqual(state.pendingCourseInvalidation(after: nil)?.authenticationRevision,
                       state.authenticationRevision)
        XCTAssertEqual(api.requests.filter { $0.method == "PUT" }.count, 1)
    }

    @MainActor
    func testRotationToDifferentOwnerAndLogoutRejectLatePut() async throws {
        let api = AcademicTimeAPIStub()
        let gate = AcademicTimeGate()
        api.putGate = gate
        api.responder = { method, path, _ in
            if method == "PUT" { await gate.pause(); return Data(#"{"sessions_generated":4}"#.utf8) }
            if path == "/api/v1/terms" { return Data("[\(self.termJSON)]".utf8) }
            return Data("[\(self.periodJSON)]".utf8)
        }
        let session = AcademicTimeSessionStore()
        session.save(cookie: "session=alice")
        let auth = AcademicTimeAuth()
        let state = AppState(api: api, sessionStore: session, authentication: auth)
        await state.restoreSession()
        let model = AcademicTimeViewModel(state: state, service: AcademicTimeService(api: api))
        await model.load()
        model.firstMonday = try XCTUnwrap(AcademicTimeValidation.date("2026-09-07"))
        let pending = Task { await model.saveTerm() }
        defer { gate.release(); pending.cancel() }
        await fulfillment(of: [gate.arrived], timeout: 3)
        guard gate.didArrive else { return }
        session.save(cookie: "session=rotated")
        auth.verifiedUsername = "bob"
        await state.reverifyRotatedSession()
        gate.release()
        await pending.value
        XCTAssertEqual(state.entry, .login)
        XCTAssertTrue(state.pendingAcademicTimeWrites.isEmpty)
        XCTAssertNil(state.pendingCourseInvalidation(after: nil))
    }

    @MainActor
    func testOfflineRotationRetainsWriteUntilSameOwnerIsReverified() async throws {
        let api = AcademicTimeAPIStub()
        let gate = AcademicTimeGate()
        api.putGate = gate
        api.responder = { method, path, _ in
            if method == "PUT" { await gate.pause(); return Data(#"{"sessions_generated":4}"#.utf8) }
            if path == "/api/v1/terms" {
                let date = api.requests.contains { $0.method == "PUT" } ? "2026-09-07" : "2026-08-31"
                return Data("[\(self.termJSON.replacingOccurrences(of: "2026-08-31", with: date))]".utf8)
            }
            return Data("[\(self.periodJSON)]".utf8)
        }
        let session = AcademicTimeSessionStore()
        session.save(cookie: "session=alice")
        let auth = AcademicTimeAuth()
        let state = AppState(api: api, sessionStore: session, authentication: auth)
        await state.restoreSession()
        let model = AcademicTimeViewModel(state: state, service: AcademicTimeService(api: api))
        await model.load()
        model.firstMonday = try XCTUnwrap(AcademicTimeValidation.date("2026-09-07"))
        let pending = Task { await model.saveTerm() }
        defer { gate.release(); pending.cancel() }
        await fulfillment(of: [gate.arrived], timeout: 3)
        guard gate.didArrive else { return }
        session.save(cookie: "session=rotated")
        auth.verificationError = .connection
        await state.reverifyRotatedSession()
        gate.release()
        await pending.value
        XCTAssertEqual(state.entry, .offline)
        XCTAssertEqual(state.pendingAcademicTimeWrites.count, 1)
        XCTAssertNil(state.pendingCourseInvalidation(after: nil))
        auth.verificationError = nil
        await state.retrySessionVerification()
        XCTAssertEqual(state.entry, .main)
        XCTAssertTrue(state.pendingAcademicTimeWrites.isEmpty)
        XCTAssertEqual(state.pendingCourseInvalidation(after: nil)?.owner, "user:alice")
    }

    @MainActor
    func testConsecutiveWritesUseDifferentInvalidationSequences() async throws {
        let api = AcademicTimeAPIStub()
        api.responder = { method, path, _ in
            if method == "PUT" { return Data(#"{"sessions_generated":4}"#.utf8) }
            if path == "/api/v1/terms" {
                let writes = api.requests.filter { $0.method == "PUT" }.count
                let date = writes == 0 ? "2026-08-31" : writes == 1 ? "2026-09-07" : "2026-09-14"
                return Data("[\(self.termJSON.replacingOccurrences(of: "2026-08-31", with: date))]".utf8)
            }
            return Data("[\(self.periodJSON)]".utf8)
        }
        let session = AcademicTimeSessionStore()
        session.save(cookie: "session=alice")
        let state = AppState(api: api, sessionStore: session, authentication: AcademicTimeAuth())
        await state.restoreSession()
        let model = AcademicTimeViewModel(state: state, service: AcademicTimeService(api: api))
        await model.load()
        model.firstMonday = try XCTUnwrap(AcademicTimeValidation.date("2026-09-07"))
        await model.saveTerm()
        let first = try XCTUnwrap(state.pendingCourseInvalidation(after: nil))
        model.firstMonday = try XCTUnwrap(AcademicTimeValidation.date("2026-09-14"))
        await model.saveTerm()
        let second = try XCTUnwrap(state.pendingCourseInvalidation(after: first.sequence))
        XCTAssertGreaterThan(second.sequence, first.sequence)
        XCTAssertEqual(state.pendingCourseInvalidation(after: nil), second)
        XCTAssertEqual(api.requests.filter { $0.method == "PUT" }.count, 2)
    }

    @MainActor
    func testStrictCacheWriteFailureKeepsOldSnapshotAndNormalRefreshTolerance() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("occupied".utf8).write(to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = AcademicTimeSessionStore()
        session.save(cookie: "session=alice")
        let account = VerifiedAccountContext()
        try account.confirm(username: "alice", cookie: "session=alice")
        let api = AcademicTimeAPIStub()
        api.responder = { _, path, _ in
            switch path {
            case "/api/v1/auth/me": return Data(#"{"username":"alice"}"#.utf8)
            case "/api/v1/timetable": return Data("[]".utf8)
            case "/api/v1/terms": return Data("[\(self.termJSON)]".utf8)
            case "/api/v1/settings/period-times": return Data("[\(self.periodJSON)]".utf8)
            default: throw APIError.connection
            }
        }
        let repository = DiskCourseRepository(api: api, session: session, account: account, directory: folder)
        let today = TodayViewModel(repository: repository,
                                   wallpaperStore: WallpaperStore(session: session, account: account, directory: folder))
        let strict = await today.refreshStrict(isCurrent: { true })
        XCTAssertFalse(strict.completed)
        XCTAssertNil(today.snapshot)
        XCTAssertNil(try repository.cached())
        let normal = try await repository.refresh(on: Date())
        XCTAssertEqual(normal.terms.count, 1)
    }

    @MainActor
    func testOldNormalRefreshCannotOverwriteNewerStrictSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = AcademicTimeSessionStore()
        session.save(cookie: "session=alice")
        let account = VerifiedAccountContext()
        try account.confirm(username: "alice", cookie: "session=alice")
        let gate = AcademicTimeGate()
        var termReads = 0
        let api = AcademicTimeAPIStub()
        api.responder = { _, path, _ in
            switch path {
            case "/api/v1/auth/me": return Data(#"{"username":"alice"}"#.utf8)
            case "/api/v1/timetable": return Data("[]".utf8)
            case "/api/v1/terms":
                termReads += 1
                if termReads == 1 {
                    await gate.pause()
                    return Data("[\(self.termJSON)]".utf8)
                }
                return Data("[\(self.termJSON.replacingOccurrences(of: "2026-08-31", with: "2026-09-07"))]".utf8)
            case "/api/v1/settings/period-times": return Data("[\(self.periodJSON)]".utf8)
            default: return Data("[]".utf8)
            }
        }
        let repository = DiskCourseRepository(api: api, session: session, account: account, directory: folder)
        let old = Task { try await repository.refresh(on: Date()) }
        defer { gate.release(); old.cancel() }
        await fulfillment(of: [gate.arrived], timeout: 3)
        guard gate.didArrive else { return }
        let fresh = try await repository.refreshStrict(on: Date(), isCurrent: { true })
        XCTAssertEqual(fresh.terms.first?.startDate, "2026-09-07")
        gate.release()
        do { _ = try await old.value; XCTFail("Superseded normal refresh should be rejected") }
        catch { XCTAssertEqual(try repository.cached()?.terms.first?.startDate, "2026-09-07") }
    }

    @MainActor
    func testAcceptedPutWaitsForInFlightCookieVerification() async throws {
        let api = AcademicTimeAPIStub()
        let putGate = AcademicTimeGate()
        let authGate = AcademicTimeGate()
        api.putGate = putGate
        api.responder = { method, path, _ in
            if method == "PUT" { await putGate.pause(); return Data(#"{"sessions_generated":4}"#.utf8) }
            if path == "/api/v1/terms" {
                let date = api.requests.contains { $0.method == "PUT" } ? "2026-09-07" : "2026-08-31"
                return Data("[\(self.termJSON.replacingOccurrences(of: "2026-08-31", with: date))]".utf8)
            }
            return Data("[\(self.periodJSON)]".utf8)
        }
        let session = AcademicTimeSessionStore()
        session.save(cookie: "session=alice")
        let auth = AcademicTimeAuth()
        let state = AppState(api: api, sessionStore: session, authentication: auth)
        await state.restoreSession()
        let model = AcademicTimeViewModel(state: state, service: AcademicTimeService(api: api))
        await model.load()
        model.firstMonday = try XCTUnwrap(AcademicTimeValidation.date("2026-09-07"))
        let pending = Task { await model.saveTerm() }
        defer { putGate.release(); authGate.release(); pending.cancel() }
        await fulfillment(of: [putGate.arrived], timeout: 3)
        guard putGate.didArrive else { return }
        session.save(cookie: "session=rotated")
        auth.verificationGate = authGate
        let verification = Task { await state.reverifyRotatedSession() }
        defer { verification.cancel() }
        await fulfillment(of: [authGate.arrived], timeout: 3)
        guard authGate.didArrive else { return }
        putGate.release()
        await pending.value
        XCTAssertEqual(state.pendingAcademicTimeWrites.first?.phase, .awaitingConfirmation)
        XCTAssertNil(state.pendingCourseInvalidation(after: nil))
        authGate.release()
        await verification.value
        XCTAssertTrue(state.pendingAcademicTimeWrites.isEmpty)
        XCTAssertEqual(state.pendingCourseInvalidation(after: nil)?.owner, "user:alice")
        XCTAssertEqual(api.requests.filter { $0.method == "PUT" }.count, 1)
    }

}

@MainActor
private final class AcademicTimeGate {
    let arrived = XCTestExpectation(description: "Request reached gate")
    private(set) var didArrive = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func pause() async {
        didArrive = true
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
private final class AcademicTimeAPIStub: APIClientProtocol {
    struct Request {
        let method: String
        let path: String
        let body: Data?
    }
    var requests: [Request] = []
    var timetableGate: AcademicTimeGate?
    var putGate: AcademicTimeGate?
    var responder: ((String, String, Data?) async throws -> Data)?

    func request<Value: Decodable>(_ method: String, path: String, body: Data?,
                                   preserveSessionOnPasswordError: Bool) async throws -> Value {
        requests.append(Request(method: method, path: path, body: body))
        guard let responder else { throw APIError.invalidResponse }
        let payload = try await responder(method, path, body)
        return try JSONDecoder().decode(Value.self, from: payload)
    }
}

private final class AcademicTimeSessionStore: SessionStore {
    private(set) var cookie: String?
    func save(cookie: String) { self.cookie = cookie }
    @discardableResult func clear() -> Bool { cookie = nil; return true }
}

private final class AcademicTimeAuth: AuthenticationClientProtocol {
    var verifiedUsername = "alice"
    var verificationError: APIError?
    var verificationGate: AcademicTimeGate?
    func login(username: String, password: String) async throws -> (cookie: String, identity: VerifiedIdentity) {
        ("session=\(username)", VerifiedIdentity(authenticated: true, username: username))
    }
    func verify(cookie: String) async throws -> VerifiedIdentity {
        await verificationGate?.pause()
        if let verificationError { throw verificationError }
        return VerifiedIdentity(authenticated: true, username: verifiedUsername)
    }
    func logout(cookie: String) async throws {}
}
