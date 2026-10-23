import XCTest
import UIKit
@testable import HandHelperNative

final class ProfileTests: XCTestCase {
    @MainActor
    func testDefaultSaveAvatarRemovalAndRestart() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = ProfileTestSessionStore()
        let account = VerifiedAccountContext()
        let store = LocalProfileStore(session: session, account: account, directory: folder)
        session.save(cookie: "session=alice")
        XCTAssertThrowsError(try store.load())
        try account.confirm(username: "Alice", cookie: "session=alice")
        XCTAssertEqual(try store.load(), .empty)
        XCTAssertEqual(try store.load().resolvedDisplayName, "航的助手")

        let avatar = sampleAvatar()
        let saved = try store.save(LocalProfile(displayName: "  小航  ", avatarData: avatar))
        XCTAssertEqual(saved.displayName, "小航")
        XCTAssertEqual(saved.avatarData, avatar)
        let restarted = LocalProfileStore(session: session, account: account, directory: folder)
        XCTAssertEqual(try restarted.load(), saved)
        try restarted.save(LocalProfile(displayName: "新名字", avatarData: nil))
        XCTAssertEqual(try restarted.load().displayName, "新名字")
        XCTAssertNil(try restarted.load().avatarData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
    }

    @MainActor
    func testVerifiedOwnerIsolationAndCookieRotation() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = ProfileTestSessionStore()
        let account = VerifiedAccountContext()
        let store = LocalProfileStore(session: session, account: account, directory: folder)
        session.save(cookie: "session=alice")
        try account.confirm(username: "alice", cookie: "session=alice")
        try store.save(LocalProfile(displayName: "Alice", avatarData: sampleAvatar()))

        session.save(cookie: "session=rotated")
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(.empty))
        try account.confirm(username: "alice", cookie: "session=rotated")
        XCTAssertEqual(try store.load().displayName, "Alice")

        account.clear()
        session.clear()
        XCTAssertThrowsError(try store.load())
        session.save(cookie: "session=bob")
        XCTAssertThrowsError(try store.load())
        try account.confirm(username: "bob", cookie: "session=bob")
        XCTAssertEqual(try store.load(), .empty)
        try store.save(LocalProfile(displayName: "Bob", avatarData: nil))
        session.save(cookie: "session=alice-new")
        XCTAssertThrowsError(try store.load())
        try account.confirm(username: "ALICE", cookie: "session=alice-new")
        XCTAssertEqual(try store.load().displayName, "Alice")
        session.save(cookie: "session=bob-new")
        try account.confirm(username: "bob", cookie: "session=bob-new")
        XCTAssertEqual(try store.load().displayName, "Bob")
    }

    @MainActor
    func testInvalidNameCorruptFileAndFailedWrite() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = ProfileTestSessionStore()
        let account = VerifiedAccountContext()
        session.save(cookie: "session=alice")
        try account.confirm(username: "alice", cookie: "session=alice")
        let store = LocalProfileStore(session: session, account: account, directory: folder)
        XCTAssertThrowsError(try store.save(LocalProfile(displayName: "   ", avatarData: nil)))
        XCTAssertThrowsError(try store.save(LocalProfile(displayName: String(repeating: "字", count: 65), avatarData: nil)))
        XCTAssertThrowsError(try store.save(LocalProfile(displayName: String(repeating: "😀", count: 33), avatarData: nil)))
        XCTAssertThrowsError(try store.save(LocalProfile(displayName: nil, avatarData: Data([1, 2, 3]))))
        try store.save(LocalProfile(displayName: "Alice", avatarData: nil))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try store.load())

        let invalidDirectory = folder.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: invalidDirectory)
        let unwritable = LocalProfileStore(session: session, account: account, directory: invalidDirectory)
        XCTAssertThrowsError(try unwritable.save(LocalProfile(displayName: "Alice", avatarData: nil)))
    }

    @MainActor
    func testAppStateLoadsOnlyAfterVerificationAndClearsOnLogoutAndSwitch() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = testPreferences()
        defer { preferences.removePersistentDomain(forName: preferencesSuite(preferences)) }
        let session = ProfileTestSessionStore()
        let auth = ProfileTestAuthentication()
        session.save(cookie: "session=alice")
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth,
                             preferences: preferences, profileDirectory: folder)
        XCTAssertEqual(state.currentProfile, .empty)
        XCTAssertNil(state.homeAvatar)
        XCTAssertThrowsError(try state.saveLocalProfile(LocalProfile(displayName: "非法", avatarData: nil), revision: 0))
        await state.restoreSession()
        XCTAssertEqual(state.entry, .main)
        let aliceRevision = state.authenticationRevision
        let avatar = sampleAvatar()
        try state.saveLocalProfile(LocalProfile(displayName: "Alice", avatarData: avatar), revision: aliceRevision)
        XCTAssertEqual(state.currentProfile.displayName, "Alice")
        XCTAssertNotNil(state.homeAvatar)

        await state.logout()
        XCTAssertEqual(state.currentProfile, .empty)
        XCTAssertNil(state.homeAvatar)
        XCTAssertThrowsError(try state.saveLocalProfile(.empty, revision: aliceRevision))
        await state.login(username: "bob", password: "fixture")
        XCTAssertEqual(state.currentProfile, .empty)
        XCTAssertNil(state.homeAvatar)
        XCTAssertThrowsError(try state.saveLocalProfile(.empty, revision: aliceRevision))
        await state.logout()
        await state.login(username: "alice", password: "fixture")
        XCTAssertEqual(state.currentProfile.displayName, "Alice")
        XCTAssertNotNil(state.homeAvatar)
    }

    @MainActor
    func testFailedSaveDoesNotPublishDraftAndOldRevisionIsRejected() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = testPreferences()
        defer { preferences.removePersistentDomain(forName: preferencesSuite(preferences)) }
        let session = ProfileTestSessionStore()
        let auth = ProfileTestAuthentication()
        let state = AppState(api: MockAPIClient(), sessionStore: session, authentication: auth,
                             preferences: preferences, profileDirectory: folder)
        await state.login(username: "alice", password: "fixture")
        let oldRevision = state.authenticationRevision
        XCTAssertThrowsError(try state.saveLocalProfile(LocalProfile(displayName: "   ", avatarData: nil), revision: oldRevision))
        XCTAssertEqual(state.currentProfile, .empty)

        await state.logout()
        await state.login(username: "bob", password: "fixture")
        XCTAssertThrowsError(try state.saveLocalProfile(LocalProfile(displayName: "旧请求", avatarData: nil), revision: oldRevision))
        XCTAssertEqual(state.currentProfile, .empty)
        let bobRevision = state.authenticationRevision
        try state.saveLocalProfile(LocalProfile(displayName: "Bob", avatarData: nil), revision: bobRevision)
        XCTAssertEqual(state.currentProfile.displayName, "Bob")
    }

    @MainActor
    func testAppStateCookieRotationReloadsOnlyVerifiedOwnerProfile() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = testPreferences()
        defer { preferences.removePersistentDomain(forName: preferencesSuite(preferences)) }
        let session = ProfileTestSessionStore()
        let state = AppState(api: MockAPIClient(), sessionStore: session,
                             authentication: ProfileTestAuthentication(),
                             preferences: preferences, profileDirectory: folder)
        await state.login(username: "alice", password: "fixture")
        try state.saveLocalProfile(LocalProfile(displayName: "Alice", avatarData: sampleAvatar()),
                                   revision: state.authenticationRevision)
        let previousRevision = state.authenticationRevision
        session.save(cookie: "session=rotated")
        XCTAssertFalse(state.canAccessPrivateData)
        XCTAssertThrowsError(try state.saveLocalProfile(.empty, revision: previousRevision))
        await state.reverifyRotatedSession()
        XCTAssertTrue(state.canAccessPrivateData)
        XCTAssertEqual(state.currentProfile.displayName, "Alice")
        XCTAssertNotNil(state.homeAvatar)
        XCTAssertNotEqual(state.authenticationRevision, previousRevision)
    }

    @MainActor
    func testAppStateWriteFailureKeepsPublishedProfile() async throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalidDirectory = root.appendingPathComponent("file-instead-of-directory")
        try Data([1]).write(to: invalidDirectory)
        let preferences = testPreferences()
        defer { preferences.removePersistentDomain(forName: preferencesSuite(preferences)) }
        let state = AppState(api: MockAPIClient(), sessionStore: ProfileTestSessionStore(),
                             authentication: ProfileTestAuthentication(),
                             preferences: preferences, profileDirectory: invalidDirectory)
        await state.login(username: "alice", password: "fixture")
        XCTAssertEqual(state.currentProfile, .empty)
        XCTAssertThrowsError(try state.saveLocalProfile(
            LocalProfile(displayName: "未保存", avatarData: nil), revision: state.authenticationRevision))
        XCTAssertEqual(state.currentProfile, .empty)
        XCTAssertNil(state.homeAvatar)
    }

    @MainActor
    func testCorruptProfileFallsBackWithoutBlockingVerifiedAccount() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = testPreferences()
        defer { preferences.removePersistentDomain(forName: preferencesSuite(preferences)) }
        let session = ProfileTestSessionStore()
        let state = AppState(api: MockAPIClient(), sessionStore: session,
                             authentication: ProfileTestAuthentication(),
                             preferences: preferences, profileDirectory: folder)
        await state.login(username: "alice", password: "fixture")
        try state.saveLocalProfile(LocalProfile(displayName: "Alice", avatarData: nil),
                                   revision: state.authenticationRevision)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder,
                                    includingPropertiesForKeys: nil).first)
        try Data("corrupt".utf8).write(to: file)
        await state.logout()
        await state.login(username: "alice", password: "fixture")
        XCTAssertEqual(state.entry, .main)
        XCTAssertEqual(state.currentProfile, .empty)
        XCTAssertNotNil(state.profileError)
    }

    func testDraftCancelAndDefaultNameAreNotImplicitlySaved() {
        let original = LocalProfile.empty
        XCTAssertFalse(ProfileDraftState.isDirty(original: original, name: "航的助手", avatar: nil))
        XCTAssertNil(ProfileDraftState.candidate(original: original, name: "航的助手", avatar: nil).displayName)
        XCTAssertTrue(ProfileDraftState.isDirty(original: original, name: "小航", avatar: nil))
        XCTAssertEqual(original, .empty) // Cancelling discards the candidate without mutating the source.
    }

    @MainActor
    func testAvatarProcessingProducesSquareBoundedJPEG() async throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        let data = try XCTUnwrap(source.jpegData(compressionQuality: 0.9))
        let prepared = try await AvatarImageProcessor.prepare(data)
        let result = try await AvatarImageProcessor.crop(prepared,
            normalizedRect: CGRect(x: 0.125, y: 0, width: 0.75, height: 1))
        let decoded = try XCTUnwrap(UIImage(data: result))
        XCTAssertEqual(decoded.size.width, 512)
        XCTAssertEqual(decoded.size.height, 512)
        XCTAssertLessThanOrEqual(result.count, 1_000_000)
        do { _ = try await AvatarImageProcessor.prepare(Data(repeating: 1, count: 15_000_001)); XCTFail("Expected size limit") }
        catch AvatarImageError.oversizedSource {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func testPreferences() -> UserDefaults {
        let suite = "ProfileTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(suite, forKey: "profile_test_suite")
        return preferences
    }

    private func preferencesSuite(_ preferences: UserDefaults) -> String {
        preferences.dictionaryRepresentation()["profile_test_suite"] as? String ?? ""
    }

    private func sampleAvatar() -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }
}

private final class ProfileTestSessionStore: SessionStore {
    private(set) var cookie: String?
    func save(cookie: String) { self.cookie = cookie }
    @discardableResult func clear() -> Bool { cookie = nil; return true }
}

private final class ProfileTestAuthentication: AuthenticationClientProtocol {
    func login(username: String, password: String) async throws -> (cookie: String, identity: VerifiedIdentity) {
        ("session=\(username)", VerifiedIdentity(authenticated: true, username: username))
    }
    func verify(cookie: String) async throws -> VerifiedIdentity {
        VerifiedIdentity(authenticated: true, username: "alice")
    }
    func logout(cookie: String) async throws {}
}
