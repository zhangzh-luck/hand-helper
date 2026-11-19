import Foundation
import XCTest
@testable import HandHelperNative

final class WeatherTests: XCTestCase {
    private let city = WeatherCity(id: 1, name: "昆明", latitude: 25.0, longitude: 102.7,
                                   admin1: "云南", country: "中国", countryCode: "CN")
    private let reading = WeatherReading(temperature: 18.2, apparentTemperature: 17.1, code: 2, isDay: 1)

    func testForecastAndCityJSONParsing() throws {
        let forecast = #"{"current":{"temperature_2m":18.2,"apparent_temperature":17.1,"weather_code":2,"is_day":1}}"#
        XCTAssertEqual(try JSONDecoder().decode(WeatherForecast.self, from: Data(forecast.utf8)).current, reading)
        let json = #"{"results":[{"id":1,"name":"昆明","latitude":25.0,"longitude":102.7,"admin1":"云南","country":"中国","country_code":"CN"}]}"#
        XCTAssertEqual(try JSONDecoder().decode(WeatherSearchResponse.self, from: Data(json.utf8)).results?.first, city)
        let ip = #"{"success":false,"message":"reserved range"}"#
        XCTAssertFalse(try JSONDecoder().decode(WeatherIPCity.self, from: Data(ip.utf8)).success)
    }

    func testWeatherCodesAndDayNight() {
        XCTAssertEqual(WeatherDescription.appearance(code: 0, isDay: true).symbol, "sun.max.fill")
        XCTAssertEqual(WeatherDescription.appearance(code: 0, isDay: false).symbol, "moon.stars.fill")
        XCTAssertEqual(WeatherDescription.appearance(code: 95, isDay: true).text, "雷雨")
        XCTAssertEqual(WeatherDescription.appearance(code: 999, isDay: true).text, "天气未知")
    }

    func testCityLabelsRetainRegionForDisambiguation() {
        let first = WeatherCity(id: 10, name: "同名", latitude: 25, longitude: 103,
                                admin1: "云南", admin2: "地区甲", country: "中国", countryCode: "CN")
        let second = WeatherCity(id: 11, name: "同名", latitude: 26, longitude: 104,
                                 admin1: "云南", admin2: "地区乙", country: "中国", countryCode: "CN")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.detail, second.detail)
    }

    func testCacheExpiresAtThirtyMinutes() {
        let time = Date(timeIntervalSince1970: 10_000)
        let cache = WeatherCache(city: city, reading: reading, savedAt: time)
        XCTAssertTrue(cache.isValid(at: time.addingTimeInterval(1799)))
        XCTAssertFalse(cache.isValid(at: time.addingTimeInterval(1800)))
        XCTAssertFalse(cache.isValid(at: time.addingTimeInterval(-1)))
    }

    @MainActor
    func testIPFailureAllowsManualSelection() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let service = WeatherServiceStub(automatic: nil, reading: reading, failAutomatic: true)
        let model = WeatherViewModel(service: service, defaults: defaults)
        model.loadIfNeeded()
        try await settle(model)
        XCTAssertTrue(model.needsCity)
        model.choose(city)
        try await settle(model)
        XCTAssertEqual(model.cache?.city, city)
    }

    @MainActor
    func testManualCityWinsAndAvoidsIPLookup() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(try JSONEncoder().encode(city), forKey: "weather.manualCity.v1")
        let service = WeatherServiceStub(automatic: nil, reading: reading)
        let model = WeatherViewModel(service: service, defaults: defaults)
        model.loadIfNeeded()
        try await settle(model)
        XCTAssertEqual(model.cache?.city, city)
        let calls = await service.automaticCalls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testExpiredCacheRefreshesAndFreshCacheAvoidsDuplicateRequests() async throws {
        let time = Date(timeIntervalSince1970: 20_000)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let expired = WeatherCache(city: city, reading: reading, savedAt: time.addingTimeInterval(-1800))
        defaults.set(try JSONEncoder().encode(city), forKey: "weather.manualCity.v1")
        defaults.set(try JSONEncoder().encode(expired), forKey: "weather.cityForecast.v1")
        let service = WeatherServiceStub(automatic: nil, reading: reading)
        let model = WeatherViewModel(service: service, defaults: defaults, now: { time })
        XCTAssertNil(model.cache)
        model.loadIfNeeded()
        try await settle(model)
        model.loadIfNeeded()
        let calls = await service.forecastCalls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.cache?.savedAt, time)
    }

    @MainActor
    func testSwitchIgnoresEarlierAutomaticResult() async throws {
        let other = WeatherCity(id: 2, name: "大理", latitude: 25.6, longitude: 100.2,
                                admin1: "云南", country: "中国", countryCode: "CN")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let started = expectation(description: "automatic lookup started")
        let service = WeatherServiceStub(automatic: city, reading: reading, delayAutomatic: true,
                                         automaticStarted: started)
        let model = WeatherViewModel(service: service, defaults: defaults)
        model.loadIfNeeded()
        await fulfillment(of: [started], timeout: 3)
        model.choose(other)
        try await settle(model)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(model.cache?.city, other)
    }

    @MainActor
    func testNetworkFailureKeepsValidCache() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let cached = WeatherCache(city: city, reading: reading, savedAt: now)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(try JSONEncoder().encode(city), forKey: "weather.manualCity.v1")
        defaults.set(try JSONEncoder().encode(cached), forKey: "weather.cityForecast.v1")
        let service = WeatherServiceStub(automatic: nil, reading: reading, failForecast: true)
        let model = WeatherViewModel(service: service, defaults: defaults, now: { now })
        model.retry()
        try await settle(model)
        XCTAssertEqual(model.cache, cached)
        XCTAssertFalse(model.needsCity)
    }

    @MainActor
    private func settle(_ model: WeatherViewModel) async throws {
        for _ in 0..<100 where model.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.loading)
    }
}

private actor WeatherServiceStub: WeatherServing {
    let automatic: WeatherCity?
    let reading: WeatherReading
    let delayAutomatic: Bool
    let failForecast: Bool
    let failAutomatic: Bool
    let automaticStarted: XCTestExpectation?
    private(set) var automaticCalls = 0
    private(set) var forecastCalls = 0

    init(automatic: WeatherCity?, reading: WeatherReading, delayAutomatic: Bool = false,
         failForecast: Bool = false, failAutomatic: Bool = false, automaticStarted: XCTestExpectation? = nil) {
        self.automatic = automatic; self.reading = reading
        self.delayAutomatic = delayAutomatic; self.failForecast = failForecast
        self.failAutomatic = failAutomatic; self.automaticStarted = automaticStarted
    }
    func automaticCity() async throws -> WeatherCity? {
        automaticCalls += 1
        automaticStarted?.fulfill()
        if delayAutomatic { try? await Task.sleep(nanoseconds: 100_000_000) }
        if failAutomatic { throw URLError(.notConnectedToInternet) }
        return automatic
    }
    func search(_ name: String, countryCode: String?) async throws -> [WeatherCity] { [] }
    func forecast(for city: WeatherCity) async throws -> WeatherReading {
        forecastCalls += 1
        if failForecast { throw URLError(.notConnectedToInternet) }
        return reading
    }
}
