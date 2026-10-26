import UIKit
import XCTest
@testable import HandHelperNative

final class WallpaperSettingsTests: XCTestCase {
    @MainActor
    func testSelectionPublishesImmediateChangeAndDefaultRestoresBackground() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = WallpaperTestSession()
        session.save(cookie: "session=fixture")
        let suite = "wallpaper-settings-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let state = AppState(api: MockAPIClient(), sessionStore: session,
                             authentication: WallpaperTestAuthentication(), preferences: preferences)
        await state.restoreSession()
        XCTAssertTrue(state.canAccessPrivateData)
        let store = WallpaperStore(session: session, account: state.verifiedAccount, directory: folder)
        let model = WallpaperSettingsModel(state: state, revision: state.authenticationRevision, store: store)
        model.load()
        XCTAssertNil(model.wallpaperData)

        let image = sampleImage()
        await model.replace { image }
        XCTAssertEqual(model.wallpaperData, image)
        XCTAssertEqual(state.wallpaperVersion, 1)
        let repository = DiskCourseRepository(api: MockAPIClient(), session: session,
                                              account: state.verifiedAccount, directory: folder)
        let today = TodayViewModel(repository: repository, wallpaperStore: store)
        today.load()
        XCTAssertEqual(today.wallpaperData, image)

        model.restoreDefault()
        XCTAssertNil(model.wallpaperData)
        XCTAssertEqual(state.wallpaperVersion, 2)
        try today.reloadWallpaper()
        XCTAssertNil(today.wallpaperData)
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testCancelledSelectionAndLogoutCannotWriteLateImage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = WallpaperTestSession()
        session.save(cookie: "session=fixture")
        let suite = "wallpaper-settings-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let state = AppState(api: MockAPIClient(), sessionStore: session,
                             authentication: WallpaperTestAuthentication(), preferences: preferences)
        await state.restoreSession()
        let store = WallpaperStore(session: session, account: state.verifiedAccount, directory: folder)
        let model = WallpaperSettingsModel(state: state, revision: state.authenticationRevision, store: store)
        let gate = WallpaperPhotoGate()
        let started = expectation(description: "Photo loading started")
        let operation = Task { await model.replace { await gate.wait(started: started) } }
        await fulfillment(of: [started], timeout: 3)

        await state.logout()
        model.cancelSelection()
        gate.cancel()
        operation.cancel()
        await operation.value
        XCTAssertNil(model.wallpaperData)
        XCTAssertEqual(state.wallpaperVersion, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("today_wallpaper_device_v1.image").path
        ))
    }

    @MainActor
    func testInvalidImageDoesNotReplaceExistingWallpaper() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = WallpaperTestSession()
        session.save(cookie: "session=fixture")
        let suite = "wallpaper-settings-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let state = AppState(api: MockAPIClient(), sessionStore: session,
                             authentication: WallpaperTestAuthentication(), preferences: preferences)
        await state.restoreSession()
        let store = WallpaperStore(session: session, account: state.verifiedAccount, directory: folder)
        let image = sampleImage()
        try store.save(image)
        let model = WallpaperSettingsModel(state: state, revision: state.authenticationRevision, store: store)
        model.load()
        await model.replace { Data([1, 2, 3]) }
        XCTAssertEqual(model.wallpaperData, image)
        XCTAssertEqual(try store.load(), image)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(state.wallpaperVersion, 0)
    }

    @MainActor
    func testCourseRefreshCannotRestorePreviousWallpaper() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = WallpaperTestSession()
        session.save(cookie: "session=fixture")
        let account = VerifiedAccountContext()
        try account.confirm(username: "tester", cookie: "session=fixture")
        let store = WallpaperStore(session: session, account: account, directory: folder)
        try store.save(Data([1, 2, 3]))
        let gate = WallpaperPhotoGate()
        let started = expectation(description: "Course refresh started")
        let repository = WallpaperRaceRepository(session: session, gate: gate, started: started)
        let today = TodayViewModel(repository: repository, wallpaperStore: store)
        today.load()
        let refresh = Task { await today.refresh() }
        await fulfillment(of: [started], timeout: 3)

        try store.remove()
        try today.reloadWallpaper()
        XCTAssertNil(today.wallpaperData)
        gate.cancel()
        await refresh.value
        XCTAssertNil(today.wallpaperData)
    }

    @MainActor
    func testTwoDeviceWallpapersPersistAndRestoreIndependently() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = WallpaperTestSession()
        session.save(cookie: "session=first")
        let account = VerifiedAccountContext()
        try account.confirm(username: "tester", cookie: "session=first")
        let today = WallpaperStore(session: session, account: account, directory: folder)
        let timetable = WallpaperStore(session: session, account: account, kind: .timetable, directory: folder)
        try today.save(Data([1]))
        try timetable.save(Data([2]))
        XCTAssertEqual(try today.load(), Data([1]))
        XCTAssertEqual(try timetable.load(), Data([2]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("today_wallpaper_device_v1.image").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("timetable_wallpaper_device_v1.image").path))
        try timetable.remove()
        XCTAssertNil(try timetable.load())
        XCTAssertEqual(try today.load(), Data([1]))
        session.save(cookie: "session=rotated")
        XCTAssertThrowsError(try timetable.load()) // Cookie alone does not prove identity.
        try account.confirm(username: "tester", cookie: "session=rotated")
        XCTAssertEqual(try WallpaperStore(session: session, account: account, directory: folder).load(), Data([1]))
        XCTAssertNil(try WallpaperStore(session: session, account: account, kind: .timetable, directory: folder).load())
    }

    @MainActor
    func testTimetableWallpaperPublishesOnlyItsVersionAndRejectsLateSelection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = WallpaperTestSession()
        session.save(cookie: "session=fixture")
        let suite = "wallpaper-settings-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let state = AppState(api: MockAPIClient(), sessionStore: session,
                             authentication: WallpaperTestAuthentication(), preferences: preferences)
        await state.restoreSession()
        let todayStore = WallpaperStore(session: session, account: state.verifiedAccount, directory: folder)
        let timetableStore = WallpaperStore(session: session, account: state.verifiedAccount,
                                            kind: .timetable, directory: folder)
        let model = WallpaperSettingsModel(state: state, revision: state.authenticationRevision,
                                           store: timetableStore)
        let image = sampleImage()
        await model.replace { image }
        XCTAssertEqual(state.timetableWallpaperVersion, 1)
        XCTAssertEqual(state.wallpaperVersion, 0)
        XCTAssertEqual(try timetableStore.load(), image)
        XCTAssertNil(try todayStore.load())
        model.restoreDefault()
        XCTAssertEqual(state.timetableWallpaperVersion, 2)
        XCTAssertNil(try timetableStore.load())

        let gate = WallpaperPhotoGate()
        let started = expectation(description: "Timetable photo loading started")
        let pending = Task { await model.replace { await gate.wait(started: started) } }
        await fulfillment(of: [started], timeout: 3)
        await state.logout()
        gate.finish(image)
        await pending.value
        XCTAssertEqual(state.timetableWallpaperVersion, 2)
        XCTAssertEqual(state.wallpaperVersion, 0)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("timetable_wallpaper_device_v1.image")), Data())
    }

    @MainActor
    private func sampleImage() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }
}

@MainActor
private final class WallpaperPhotoGate {
    private var continuation: CheckedContinuation<Data?, Never>?
    private var cancelled = false

    func wait(started: XCTestExpectation) async -> Data? {
        if cancelled { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func cancel() {
        cancelled = true
        finish(nil)
    }

    func finish(_ data: Data?) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

private final class WallpaperTestSession: SessionStore {
    private(set) var cookie: String?
    func save(cookie: String) { self.cookie = cookie }
    @discardableResult func clear() -> Bool { cookie = nil; return true }
}

@MainActor
private final class WallpaperRaceRepository: CourseRepository {
    let session: WallpaperTestSession
    let gate: WallpaperPhotoGate
    let started: XCTestExpectation
    var sessionCookie: String? { session.cookie }
    var canEditSchedules: Bool { true }

    init(session: WallpaperTestSession, gate: WallpaperPhotoGate, started: XCTestExpectation) {
        self.session = session
        self.gate = gate
        self.started = started
    }

    func cached() throws -> CourseSnapshot? { .empty }
    func refresh(on date: Date) async throws -> CourseSnapshot {
        _ = await gate.wait(started: started)
        return .empty
    }
    func localSchedules(on date: Date) throws -> [CustomSchedule] { [] }
    func allLocalSchedules() throws -> [CustomSchedule] { [] }
    func saveSchedule(_ schedule: CustomSchedule) throws {}
    func deleteSchedule(id: Int) throws {}
    func saveManualRule(_ rule: ManualCourseRule) throws {}
    func saveProfile(_ profile: TodayProfile) throws {}
}

@MainActor
private final class WallpaperTestAuthentication: AuthenticationClientProtocol {
    func login(username: String, password: String) async throws -> (cookie: String, identity: VerifiedIdentity) {
        ("session=fixture", VerifiedIdentity(authenticated: true, username: username))
    }
    func verify(cookie: String) async throws -> VerifiedIdentity {
        VerifiedIdentity(authenticated: true, username: "tester")
    }
    func logout(cookie: String) async throws {}
}
