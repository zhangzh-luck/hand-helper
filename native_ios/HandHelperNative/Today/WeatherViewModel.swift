import Combine
import Foundation

struct WeatherCache: Codable, Equatable {
    let city: WeatherCity
    let reading: WeatherReading
    let savedAt: Date

    func isValid(at now: Date) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        return age >= 0 && age < 30 * 60 && reading.temperature.isFinite &&
            reading.apparentTemperature.isFinite && abs(reading.temperature) <= 150 &&
            abs(reading.apparentTemperature) <= 150 && (reading.isDay == 0 || reading.isDay == 1) &&
            city.latitude.isFinite && city.longitude.isFinite &&
            (-90.0...90.0).contains(city.latitude) && (-180.0...180.0).contains(city.longitude)
    }
}

@MainActor
final class WeatherViewModel: ObservableObject {
    @Published private(set) var cache: WeatherCache?
    @Published private(set) var loading = false
    @Published private(set) var needsCity = false
    @Published private(set) var selectedManualCity: WeatherCity?
    private(set) var enabled: Bool
    private let service: any WeatherServing
    private let defaults: UserDefaults
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private var generation = 0
    private let cityKey = "weather.manualCity.v1"
    private let cacheKey = "weather.cityForecast.v1"

    init(service: any WeatherServing = OpenMeteoWeatherService(), defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init, enabled: Bool = true) {
        self.service = service; self.defaults = defaults; self.now = now; self.enabled = enabled
        self.selectedManualCity = defaults.data(forKey: "weather.manualCity.v1").flatMap { try? JSONDecoder().decode(WeatherCity.self, from: $0) }
        if let data = defaults.data(forKey: cacheKey),
           let saved = try? JSONDecoder().decode(WeatherCache.self, from: data), saved.isValid(at: now()) {
            let manual = defaults.data(forKey: cityKey).flatMap { try? JSONDecoder().decode(WeatherCity.self, from: $0) }
            if manual == nil || manual?.id == saved.city.id { cache = saved }
        }
    }

    func loadIfNeeded() {
        guard enabled else { return }
        if let cache, cache.isValid(at: now()) { return }
        guard !loading, !needsCity else { return }
        start(manual: manualCity())
    }

    func retry() { guard enabled else { return }; start(manual: manualCity()) }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if !value {
            generation += 1; task?.cancel(); task = nil; loading = false
        } else {
            needsCity = false
            loadIfNeeded()
        }
    }

    func restoreAutomatic() {
        defaults.removeObject(forKey: cityKey)
        defaults.removeObject(forKey: cacheKey)
        selectedManualCity = nil
        cache = nil
        generation += 1; task?.cancel(); task = nil; loading = false; needsCity = false
        if enabled { start(manual: nil) }
    }

    func choose(_ city: WeatherCity) {
        let city = city.coarse
        guard let encoded = try? JSONEncoder().encode(city) else { return }
        defaults.set(encoded, forKey: cityKey)
        selectedManualCity = city
        if enabled { start(manual: city) }
        else if cache?.city.id != city.id { cache = nil; defaults.removeObject(forKey: cacheKey) }
    }

    func search(_ name: String) async throws -> [WeatherCity] {
        try await service.search(name, countryCode: nil)
    }

    private func manualCity() -> WeatherCity? {
        defaults.data(forKey: cityKey).flatMap { try? JSONDecoder().decode(WeatherCity.self, from: $0) }
    }

    private func start(manual: WeatherCity?) {
        generation += 1
        let ticket = generation
        task?.cancel()
        loading = true; needsCity = false
        // Never display another city's reading after a manual switch.
        if let manual, cache?.city.id != manual.id { cache = nil }
        if let cache, !cache.isValid(at: now()) { self.cache = nil }
        task = Task {
            do {
                let city: WeatherCity?
                if let manual { city = manual }
                else { city = try await service.automaticCity() }
                try Task.checkCancellation()
                guard ticket == generation else { return }
                guard let city = city?.coarse else { loading = false; needsCity = true; return }
                let reading = try await service.forecast(for: city)
                try Task.checkCancellation()
                guard ticket == generation else { return }
                let fresh = WeatherCache(city: city, reading: reading, savedAt: now())
                guard fresh.isValid(at: now()) else { throw URLError(.cannotParseResponse) }
                cache = fresh; loading = false; needsCity = false
                if let encoded = try? JSONEncoder().encode(fresh) { defaults.set(encoded, forKey: cacheKey) }
            } catch {
                guard ticket == generation, !Task.isCancelled else { return }
                if let cache, !cache.isValid(at: now()) { self.cache = nil }
                loading = false
                needsCity = self.cache == nil
            }
        }
    }
}
