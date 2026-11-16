import XCTest
import SwiftUI
import UIKit
@testable import HandHelperNative

final class FoundationTests: XCTestCase {
    func testAvatarPreviewClearPolicySkipsAnAlreadyIdleRoot() {
        XCTAssertFalse(AvatarPreviewClearPolicy.needsClear(isVisible: false, hasPreview: false))
        XCTAssertTrue(AvatarPreviewClearPolicy.needsClear(isVisible: true, hasPreview: false))
        XCTAssertTrue(AvatarPreviewClearPolicy.needsClear(isVisible: false, hasPreview: true))
    }

    @MainActor
    func testAvatarPreviewCoordinatorRestoresSourceForMatchingAndExternalCleanup() {
        let coordinator = AvatarPreviewCoordinator()
        let first = UUID()
        let second = UUID()

        coordinator.begin(routeID: first)
        XCTAssertTrue(coordinator.isSourceAvatarHidden)
        coordinator.finish(routeID: second)
        XCTAssertTrue(coordinator.isSourceAvatarHidden)
        coordinator.finish(routeID: first)
        XCTAssertFalse(coordinator.isSourceAvatarHidden)

        coordinator.begin(routeID: second)
        coordinator.begin(routeID: first)
        coordinator.finish(routeID: second)
        XCTAssertTrue(coordinator.isSourceAvatarHidden)
        coordinator.finish(routeID: first)
        XCTAssertFalse(coordinator.isSourceAvatarHidden)

        coordinator.begin(routeID: second)
        coordinator.clear()
        XCTAssertFalse(coordinator.isSourceAvatarHidden)
        coordinator.finish(routeID: second)
        XCTAssertFalse(coordinator.isSourceAvatarHidden)
    }

    func testSettingsNavigationSymbolsAreAvailable() {
        for symbol in ["clock", "square.and.arrow.down", "paintpalette", "photo",
                       "calendar.badge.plus", "doc.badge.plus", "house", "calendar", "chart.bar"] {
            XCTAssertNotNil(UIImage(systemName: symbol), "Missing SF Symbol: \(symbol)")
        }
    }

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
        let client = makeClient(store: store) { request in
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

    func testNonJSONUnauthorizedStillClearsSession() async throws {
        let store = MemorySessionStore()
        store.save(cookie: "session=expired")
        let client = makeClient(store: store) { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401,
                                                           httpVersion: nil, headerFields: nil))
            return (response, Data("not JSON".utf8))
        }
        do {
            let _: AuthIdentity = try await client.request("GET", path: "/api/v1/auth/me")
            XCTFail("Expected unauthorized")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized(message: "登录状态已失效，请重新登录"))
        }
        XCTAssertNil(store.cookie)
    }

    func testPasswordRecheckUnauthorizedPreservesCurrentSession() async throws {
        let store = MemorySessionStore()
        store.save(cookie: "session=valid")
        let client = makeClient(store: store) { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401,
                                                           httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"success":false,"error":{"message":"当前密码错误"}}"#.utf8))
        }
        do {
            let _: APIEmptyResponse = try await client.request(
                "POST", path: "/api/v1/auth/passkey/registration/options", body: Data("{}".utf8),
                preserveSessionOnPasswordError: true)
            XCTFail("Expected password error")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized(message: "当前密码错误"))
        }
        XCTAssertEqual(store.cookie, "session=valid")
    }

    func testLateUnauthorizedDoesNotClearReplacementCookie() async throws {
        let store = MemorySessionStore()
        store.save(cookie: "session=old")
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let client = makeClient(store: store) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=old")
            entered.signal()
            guard resume.wait(timeout: .now() + 5) == .success else {
                throw URLError(.timedOut)
            }
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401,
                                                           httpVersion: nil, headerFields: nil))
            return (response, Data("not JSON".utf8))
        }
        let pending = Task { () -> APIError? in
            do {
                let _: AuthIdentity = try await client.request("GET", path: "/api/v1/auth/me")
                return nil
            } catch { return error as? APIError }
        }
        let didEnter = await Task.detached { entered.wait(timeout: .now() + 5) }.value
        guard didEnter == .success else {
            resume.signal()
            pending.cancel()
            XCTFail("Request did not reach the URLProtocol")
            return
        }
        store.save(cookie: "session=new")
        resume.signal()
        let outcome = await pending.value
        XCTAssertEqual(outcome, APIError.unauthorized(message: "登录状态已失效，请重新登录"))
        XCTAssertEqual(store.cookie, "session=new")
    }

    func testInvalidatedRequestCannotClearReusedCookie() async throws {
        let store = MemorySessionStore()
        store.save(cookie: "session=same-value")
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let client = makeClient(store: store) { request in
            entered.signal()
            guard resume.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401,
                                                           httpVersion: nil, headerFields: nil))
            return (response, Data("not JSON".utf8))
        }
        let pending = Task { () -> APIError? in
            do {
                let _: AuthIdentity = try await client.request("GET", path: "/api/v1/auth/me")
                return nil
            } catch { return error as? APIError }
        }
        let didEnter = await Task.detached { entered.wait(timeout: .now() + 5) }.value
        guard didEnter == .success else {
            resume.signal()
            pending.cancel()
            XCTFail("Request did not reach the URLProtocol")
            return
        }
        client.invalidatePendingSessionRequests()
        resume.signal()
        let outcome = await pending.value
        XCTAssertEqual(outcome, .unauthorized(message: "登录状态已失效，请重新登录"))
        XCTAssertEqual(store.cookie, "session=same-value")
    }

    @MainActor
    func testIPadSidebarKeepsExistingControllersAndSelection() throws {
        let state = AppState(api: MockAPIClient(), sessionStore: MemorySessionStore())
        state.selectedTab = .timetable
        let controller = NativeTabController(state: state, deviceIdiom: .pad)
        let original = try XCTUnwrap(controller.viewControllers)
        XCTAssertEqual(original.count, AppTab.allCases.count)
        XCTAssertEqual(controller.selectedIndex, AppTab.timetable.rawValue)

        if #available(iOS 18.0, *) {
            XCTAssertEqual(controller.mode, .tabSidebar)
            XCTAssertEqual(original.compactMap { $0.tabBarItem.title }, AppTab.allCases.map(\.title))
        }

        state.selectedTab = .analysis
        controller.apply(state: state)
        let after = try XCTUnwrap(controller.viewControllers)
        XCTAssertEqual(controller.selectedIndex, AppTab.analysis.rawValue)
        XCTAssertTrue(zip(original, after).allSatisfy { pair in pair.0 === pair.1 })
    }

    @MainActor
    func testPhoneDoesNotEnableIPadSidebar() throws {
        let state = AppState(api: MockAPIClient(), sessionStore: MemorySessionStore())
        let controller = NativeTabController(state: state, deviceIdiom: .phone)
        XCTAssertFalse(NativeTabController.supportsIPadSidebar(deviceIdiom: .phone))
        XCTAssertTrue(try XCTUnwrap(controller.viewControllers).allSatisfy { $0.tabBarItem.title == nil })
        if #available(iOS 18.0, *) {
            XCTAssertNotEqual(controller.mode, .tabSidebar)
        }
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
        let tabs = NativeTabController(state: state)
        tabs.apply(state: state)
        XCTAssertEqual(tabs.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(AppState(api: MockAPIClient(), sessionStore: MemorySessionStore(), preferences: defaults).appearance, .dark)
        state.setAppearance(.light)
        XCTAssertEqual(state.appearance.colorScheme, .light)
        tabs.apply(state: state)
        XCTAssertEqual(tabs.overrideUserInterfaceStyle, .light)
        state.setAppearance(.system)
        tabs.apply(state: state)
        XCTAssertEqual(tabs.overrideUserInterfaceStyle, .unspecified)
    }

    @MainActor
    func testNavigationDestinationVisibilityIsScopedToSelectedTab() {
        let state = AppState(api: MockAPIClient(), sessionStore: MemorySessionStore())
        let settingsRoot = UUID()
        let settingsChild = UUID()

        state.setNavigationDestinationVisible(true, token: settingsRoot, in: .settings)
        XCTAssertFalse(state.shouldHideTabBarForNavigation)

        state.selectedTab = .settings
        XCTAssertTrue(state.shouldHideTabBarForNavigation)

        state.setNavigationDestinationVisible(true, token: settingsChild, in: .settings)
        state.setNavigationDestinationVisible(false, token: settingsRoot, in: .settings)
        XCTAssertTrue(state.shouldHideTabBarForNavigation, "A deeper destination must keep the bar hidden")

        state.selectedTab = .today
        XCTAssertFalse(state.shouldHideTabBarForNavigation, "Other root tabs remain visible")

        state.selectedTab = .settings
        state.setNavigationDestinationVisible(false, token: settingsChild, in: .settings)
        XCTAssertFalse(state.shouldHideTabBarForNavigation)
    }

    @MainActor
    func testNativeTabBarFollowsNavigationDestinationVisibility() {
        let state = AppState(api: MockAPIClient(), sessionStore: MemorySessionStore())
        let tabs = NativeTabController(state: state)
        tabs.loadViewIfNeeded()
        tabs.apply(state: state)
        XCTAssertFalse(tabs.tabBar.isHidden)

        let token = UUID()
        state.selectedTab = .settings
        state.setNavigationDestinationVisible(true, token: token, in: .settings)
        tabs.apply(state: state)
        XCTAssertTrue(tabs.tabBar.isHidden)

        state.setNavigationDestinationVisible(false, token: token, in: .settings)
        tabs.apply(state: state)
        XCTAssertFalse(tabs.tabBar.isHidden)
    }

    @MainActor
    func testSettingsUsesUIKitPushForSecondaryDestinations() throws {
        let state = AppState(api: MockAPIClient(), sessionStore: MemorySessionStore())
        let tabs = NativeTabController(state: state)
        let navigation = try XCTUnwrap(
            tabs.viewControllers?[AppTab.settings.rawValue] as? SettingsNavigationController
        )

        XCTAssertEqual(navigation.viewControllers.count, 1)
        XCTAssertFalse(navigation.isShowingSecondaryPage)

        navigation.navigator.push(title: "测试页面") { Text("测试页面") }

        XCTAssertEqual(navigation.viewControllers.count, 2)
        XCTAssertTrue(navigation.isShowingSecondaryPage)
        XCTAssertTrue(navigation.topViewController?.hidesBottomBarWhenPushed == true)

        navigation.popViewController(animated: false)
        XCTAssertEqual(navigation.viewControllers.count, 1)
        XCTAssertFalse(navigation.isShowingSecondaryPage)
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
        store.save(cookie: "session=old-value")
        let client = makeClient(store: store) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=old-value")
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

    private func makeClient(store: MemorySessionStore,
                            handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let identifier = StubURLProtocol.register(handler)
        configuration.httpAdditionalHeaders = ["X-Foundation-Test-ID": identifier]
        return APIClient(configuration: .development, sessionStore: store,
                         session: URLSession(configuration: configuration))
    }
}

private final class StubURLProtocol: URLProtocol {
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
            let identifier = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Foundation-Test-ID"),
                                           "Foundation test request has no handler ID")
            let handler = try XCTUnwrap(Self.handler(for: identifier), "Missing URLProtocol handler")
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class MemorySessionStore: SessionStore {
    private(set) var cookie: String?
    func save(cookie: String) { self.cookie = cookie }
    @discardableResult func clear() -> Bool { cookie = nil; return true }
}
