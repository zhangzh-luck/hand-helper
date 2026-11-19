import Foundation

struct WeatherCity: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let admin1: String?
    let admin2: String?
    let country: String?
    let countryCode: String?
    let timezone: String?
    enum CodingKeys: String, CodingKey {
        case id, name, latitude, longitude, admin1, admin2, country, timezone
        case countryCode = "country_code"
    }
    init(id: Int, name: String, latitude: Double, longitude: Double, admin1: String?,
         admin2: String? = nil, country: String?, countryCode: String?, timezone: String? = nil) {
        self.id = id; self.name = name; self.latitude = latitude; self.longitude = longitude
        self.admin1 = admin1; self.admin2 = admin2; self.country = country
        self.countryCode = countryCode; self.timezone = timezone
    }
    var detail: String {
        [admin2, admin1, country, timezone].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var coarse: WeatherCity {
        WeatherCity(id: id, name: name, latitude: (latitude * 10).rounded() / 10,
                    longitude: (longitude * 10).rounded() / 10, admin1: admin1,
                    admin2: admin2, country: country, countryCode: countryCode, timezone: timezone)
    }
}

struct WeatherReading: Codable, Equatable {
    let temperature: Double
    let apparentTemperature: Double
    let code: Int
    let isDay: Int
    enum CodingKeys: String, CodingKey {
        case temperature = "temperature_2m", apparentTemperature = "apparent_temperature"
        case code = "weather_code", isDay = "is_day"
    }
}

struct WeatherForecast: Decodable { let current: WeatherReading }
struct WeatherSearchResponse: Decodable { let results: [WeatherCity]? }
struct WeatherIPCity: Decodable {
    let success: Bool
    let city: String?
    let region: String?
    let countryCode: String?
    enum CodingKeys: String, CodingKey { case success, city, region; case countryCode = "country_code" }
}

enum WeatherDescription {
    static func appearance(code: Int, isDay: Bool) -> (text: String, symbol: String) {
        switch code {
        case 0: return ("晴", isDay ? "sun.max.fill" : "moon.stars.fill")
        case 1, 2: return ("少云", isDay ? "cloud.sun.fill" : "cloud.moon.fill")
        case 3: return ("阴", "cloud.fill")
        case 45, 48: return ("雾", "cloud.fog.fill")
        case 51, 53, 55: return ("毛毛雨", "cloud.drizzle.fill")
        case 56, 57: return ("冻毛毛雨", "cloud.sleet.fill")
        case 61, 63, 65: return ("雨", "cloud.rain.fill")
        case 66, 67: return ("冻雨", "cloud.sleet.fill")
        case 71, 73, 75, 77: return ("雪", "cloud.snow.fill")
        case 80, 81, 82: return ("阵雨", "cloud.heavyrain.fill")
        case 85, 86: return ("阵雪", "cloud.snow.fill")
        case 95: return ("雷雨", "cloud.bolt.rain.fill")
        case 96, 99: return ("雷雨伴冰雹", "cloud.bolt.rain.fill")
        default: return ("天气未知", "cloud")
        }
    }
}

protocol WeatherServing {
    func automaticCity() async throws -> WeatherCity?
    func search(_ name: String, countryCode: String?) async throws -> [WeatherCity]
    func forecast(for city: WeatherCity) async throws -> WeatherReading
}

struct OpenMeteoWeatherService: WeatherServing {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: configuration)
        }
    }

    private func get<Value: Decodable>(_ type: Value.Type, components: URLComponents) async throws -> Value {
        guard let url = components.url, url.scheme == "https" else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func search(_ name: String, countryCode: String? = nil) async throws -> [WeatherCity] {
        let term = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return [] }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [URLQueryItem(name: "name", value: term), URLQueryItem(name: "count", value: "20"),
                                 URLQueryItem(name: "language", value: "zh"), URLQueryItem(name: "format", value: "json")]
        if let countryCode, countryCode.count == 2 { components.queryItems?.append(URLQueryItem(name: "countryCode", value: countryCode)) }
        return try await get(WeatherSearchResponse.self, components: components).results ?? []
    }

    func automaticCity() async throws -> WeatherCity? {
        var components = URLComponents(string: "https://ipwho.is/")!
        // Request only city-level labels; never decode or store the returned IP.
        components.queryItems = [URLQueryItem(name: "fields", value: "success,city,region,country_code"),
                                 URLQueryItem(name: "lang", value: "zh-CN")]
        let location = try await get(WeatherIPCity.self, components: components)
        guard location.success, let name = location.city, name.count >= 2 else { return nil }
        let candidates = try await search(name, countryCode: location.countryCode)
        func normalized(_ value: String) -> String {
            var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if text.hasSuffix("市") || text.hasSuffix("省") { text.removeLast() }
            return text
        }
        let exact = candidates.filter { normalized($0.name) == normalized(name) }
        if exact.count == 1 { return exact[0] }
        if let region = location.region {
            let matches = exact.filter { $0.admin1.map(normalized) == normalized(region) }
            if matches.count == 1 { return matches[0] }
        }
        return nil // Ambiguous city: ask the user instead of guessing.
    }

    func forecast(for city: WeatherCity) async throws -> WeatherReading {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [URLQueryItem(name: "latitude", value: String(city.latitude)),
                                 URLQueryItem(name: "longitude", value: String(city.longitude)),
                                 URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day")]
        return try await get(WeatherForecast.self, components: components).current
    }
}
