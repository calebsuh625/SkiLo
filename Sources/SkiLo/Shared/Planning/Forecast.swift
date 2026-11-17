import Foundation

/// One day of mountain weather (Open-Meteo daily values at the resort's forecast point).
struct DayForecast: Codable, Hashable, Identifiable, Sendable {
    var date: String            // "yyyy-MM-dd" in the resort's time zone
    var snowCm: Double
    var tempMaxC: Double
    var tempMinC: Double
    var windMaxKmh: Double
    var gustMaxKmh: Double
    var weatherCode: Int
    var id: String { date }

    var symbol: String {
        switch weatherCode {
        case 0: "sun.max.fill"
        case 1, 2: "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.fill"
        default: "cloud.fill"
        }
    }
    var summary: String {
        switch weatherCode {
        case 0: "Clear"
        case 1: "Mostly sunny"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67: "Rain"
        case 71...75: "Snow"
        case 77: "Snow grains"
        case 80...82: "Showers"
        case 85, 86: "Snow showers"
        case 95...99: "Thunderstorms"
        default: "Mixed"
        }
    }
}

struct Forecast: Codable, Equatable, Sendable {
    var resortID: String
    var fetchedAt: Date
    /// Includes the past 3 days (for recent snowfall) and the next few.
    var days: [DayForecast]

    func day(_ key: String) -> DayForecast? { days.first { $0.date == key } }
    func days(before key: String, count: Int) -> [DayForecast] {
        Array(days.filter { $0.date < key }.suffix(count))
    }
    /// Today and the following days.
    func upcoming(from key: String) -> [DayForecast] { days.filter { $0.date >= key } }
}

enum ForecastState: Equatable {
    case idle
    case loading
    case loaded(Forecast)
    case failed(String)

    var forecast: Forecast? { if case .loaded(let f) = self { f } else { nil } }
}

enum WeatherService {
    static func url(for resort: ResortInfo) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        let p = resort.weatherPoint
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", p.lat)),
            .init(name: "longitude", value: String(format: "%.4f", p.lon)),
            .init(name: "elevation", value: String(format: "%.0f", p.ele ?? 2_500)),
            .init(name: "daily", value: "snowfall_sum,temperature_2m_max,temperature_2m_min,wind_speed_10m_max,wind_gusts_10m_max,weather_code"),
            .init(name: "past_days", value: "3"),
            .init(name: "forecast_days", value: "5"),
            .init(name: "timezone", value: resort.timeZone),
        ]
        return c.url!
    }

    struct Response: Decodable {
        struct Daily: Decodable {
            var time: [String]
            var snowfall_sum: [Double?]
            var temperature_2m_max: [Double?]
            var temperature_2m_min: [Double?]
            var wind_speed_10m_max: [Double?]
            var wind_gusts_10m_max: [Double?]
            var weather_code: [Int?]
        }
        var daily: Daily
    }

    static func parse(_ data: Data, resortID: String, fetchedAt: Date = .now) throws -> Forecast {
        let d = try JSONDecoder().decode(Response.self, from: data).daily
        let days = d.time.indices.map { i in
            DayForecast(date: d.time[i],
                        snowCm: d.snowfall_sum[safe: i].flatMap { $0 } ?? 0,
                        tempMaxC: d.temperature_2m_max[safe: i].flatMap { $0 } ?? 0,
                        tempMinC: d.temperature_2m_min[safe: i].flatMap { $0 } ?? 0,
                        windMaxKmh: d.wind_speed_10m_max[safe: i].flatMap { $0 } ?? 0,
                        gustMaxKmh: d.wind_gusts_10m_max[safe: i].flatMap { $0 } ?? 0,
                        weatherCode: d.weather_code[safe: i].flatMap { $0 } ?? 3)
        }
        return Forecast(resortID: resortID, fetchedAt: fetchedAt, days: days)
    }

    /// Cached for an hour in Application Support; a stale cache is used when offline.
    static func load(for resort: ResortInfo, cacheDirectory: URL?, forceRefresh: Bool = false) async throws -> Forecast {
        let cacheURL = cacheDirectory?.appendingPathComponent("forecast-\(resort.id).json")
        var cached: Forecast?
        if let cacheURL, let data = try? Data(contentsOf: cacheURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            cached = try? dec.decode(Forecast.self, from: data)
        }
        if !forceRefresh, let c = cached, Date().timeIntervalSince(c.fetchedAt) < 3_600 { return c }
        do {
            var req = URLRequest(url: url(for: resort))
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
            let f = try parse(data, resortID: resort.id)
            if let cacheURL {
                let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? enc.encode(f).write(to: cacheURL, options: .atomic)
            }
            return f
        } catch {
            if let cached { return cached }
            throw error
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
