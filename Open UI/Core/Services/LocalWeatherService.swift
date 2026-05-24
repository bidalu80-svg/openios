import CoreLocation
import Foundation
import WeatherKit

enum LocalWeatherError: LocalizedError {
    case locationUnavailable
    case weatherUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .locationUnavailable:
            return "需要定位权限和当前位置，才能读取本地天气。"
        case .weatherUnavailable(let message):
            return "读取天气失败：\(message)"
        }
    }
}

struct LocalWeatherSnapshot: Sendable {
    let locationName: String?
    let latitude: Double
    let longitude: Double
    let date: Date
    let condition: String
    let symbolName: String
    let temperatureCelsius: Double
    let apparentTemperatureCelsius: Double
    let humidity: Double
    let windSpeedKPH: Double
    let precipitationChance: Double?
    let attributionServiceName: String
    let attributionLegalURL: URL
}

@MainActor
final class LocalWeatherService {
    static let shared = LocalWeatherService()

    private let weatherService = WeatherService.shared
    private let fallbackAttributionURL = URL(string: "https://open-meteo.com/")!

    private init() {}

    func currentWeather() async throws -> LocalWeatherSnapshot {
        let manager = LocationManager.shared
        if !manager.isLocationEnabled {
            manager.isLocationEnabled = true
            manager.requestPermissionAndStart()
        } else {
            manager.requestPermissionAndStart()
        }

        guard let location = await waitForLocation(from: manager) else {
            throw LocalWeatherError.locationUnavailable
        }

        do {
            return try await weatherKitSnapshot(for: location, manager: manager)
        } catch {
            return try await openMeteoSnapshot(for: location, manager: manager)
        }
    }

    private func waitForLocation(from manager: LocationManager) async -> CLLocation? {
        if let location = manager.cachedLocation {
            return location
        }

        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let location = manager.cachedLocation {
                return location
            }
        }

        return nil
    }

    private func weatherKitSnapshot(for location: CLLocation, manager: LocationManager) async throws -> LocalWeatherSnapshot {
        do {
            let weather = try await weatherService.weather(for: location)
            let current = weather.currentWeather
            let chance = weather.hourlyForecast.first?.precipitationChance
            let attribution = try await weatherService.attribution
            return LocalWeatherSnapshot(
                locationName: manager.cachedPlaceName,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                date: current.date,
                condition: current.condition.description,
                symbolName: current.symbolName,
                temperatureCelsius: current.temperature.converted(to: .celsius).value,
                apparentTemperatureCelsius: current.apparentTemperature.converted(to: .celsius).value,
                humidity: current.humidity,
                windSpeedKPH: current.wind.speed.converted(to: .kilometersPerHour).value,
                precipitationChance: chance,
                attributionServiceName: attribution.serviceName,
                attributionLegalURL: attribution.legalPageURL
            )
        } catch {
            throw LocalWeatherError.weatherUnavailable(error.localizedDescription)
        }
    }

    private func openMeteoSnapshot(for location: CLLocation, manager: LocationManager) async throws -> LocalWeatherSnapshot {
        do {
            let response = try await fetchOpenMeteoForecast(for: location)
            let current = response.current
            let currentDate = Self.openMeteoDate(from: current.time, timezoneID: response.timezone) ?? Date()
            let isDay = (current.isDay ?? 1) != 0
            let weatherCode = current.weatherCode ?? -1
            return LocalWeatherSnapshot(
                locationName: manager.cachedPlaceName,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                date: currentDate,
                condition: Self.weatherDescription(for: weatherCode),
                symbolName: Self.weatherSymbolName(for: weatherCode, isDay: isDay),
                temperatureCelsius: current.temperature2m ?? 0,
                apparentTemperatureCelsius: current.apparentTemperature ?? current.temperature2m ?? 0,
                humidity: Double(current.relativeHumidity2m ?? 0) / 100.0,
                windSpeedKPH: current.windSpeed10m ?? 0,
                precipitationChance: Self.precipitationChance(from: response, near: currentDate),
                attributionServiceName: "Open-Meteo",
                attributionLegalURL: fallbackAttributionURL
            )
        } catch let error as LocalWeatherError {
            throw error
        } catch {
            throw LocalWeatherError.weatherUnavailable("WeatherKit 不可用，备用天气源也失败：\(error.localizedDescription)")
        }
    }

    private func fetchOpenMeteoForecast(for location: CLLocation) async throws -> OpenMeteoForecastResponse {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(location.coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m,is_day"),
            URLQueryItem(name: "hourly", value: "precipitation_probability"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto")
        ]

        guard let url = components.url else {
            throw LocalWeatherError.weatherUnavailable("备用天气接口地址无效。")
        }

        var request = URLRequest(url: url)
        request.setValue("Iexa iOS", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw LocalWeatherError.weatherUnavailable("备用天气接口返回 HTTP \(httpResponse.statusCode)。")
        }

        return try JSONDecoder().decode(OpenMeteoForecastResponse.self, from: data)
    }

    private static func precipitationChance(from response: OpenMeteoForecastResponse, near date: Date) -> Double? {
        guard let hourly = response.hourly,
              let times = hourly.time,
              let probabilities = hourly.precipitationProbability,
              !times.isEmpty else {
            return nil
        }

        for index in times.indices {
            guard index < probabilities.count,
                  let parsedDate = openMeteoDate(from: times[index], timezoneID: response.timezone),
                  parsedDate >= date,
                  let probability = probabilities[index] else {
                continue
            }
            return min(1, max(0, probability / 100.0))
        }

        return probabilities.compactMap { $0 }.first.map { min(1, max(0, $0 / 100.0)) }
    }

    private static func openMeteoDate(from text: String, timezoneID: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        if let timezoneID, let timeZone = TimeZone(identifier: timezoneID) {
            formatter.timeZone = timeZone
        } else {
            formatter.timeZone = .current
        }
        return formatter.date(from: text)
    }

    private static func weatherDescription(for code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1: return "大部晴朗"
        case 2: return "局部多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51, 53, 55: return "毛毛雨"
        case 56, 57: return "冻毛毛雨"
        case 61, 63, 65: return "雨"
        case 66, 67: return "冻雨"
        case 71, 73, 75: return "雪"
        case 77: return "雪粒"
        case 80, 81, 82: return "阵雨"
        case 85, 86: return "阵雪"
        case 95: return "雷暴"
        case 96, 99: return "雷暴伴冰雹"
        default: return "天气"
        }
    }

    private static func weatherSymbolName(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0:
            return isDay ? "sun.max" : "moon.stars"
        case 1, 2:
            return isDay ? "cloud.sun" : "cloud.moon"
        case 3:
            return "cloud"
        case 45, 48:
            return "cloud.fog"
        case 51, 53, 55, 56, 57:
            return "cloud.drizzle"
        case 61, 63, 65, 80, 81, 82:
            return "cloud.rain"
        case 66, 67:
            return "cloud.sleet"
        case 71, 73, 75, 77, 85, 86:
            return "cloud.snow"
        case 95, 96, 99:
            return "cloud.bolt.rain"
        default:
            return "cloud.sun"
        }
    }
}

private struct OpenMeteoForecastResponse: Decodable {
    let timezone: String?
    let current: CurrentWeather
    let hourly: HourlyForecast?

    struct CurrentWeather: Decodable {
        let time: String
        let temperature2m: Double?
        let relativeHumidity2m: Int?
        let apparentTemperature: Double?
        let precipitation: Double?
        let weatherCode: Int?
        let windSpeed10m: Double?
        let isDay: Int?

        enum CodingKeys: String, CodingKey {
            case time
            case temperature2m = "temperature_2m"
            case relativeHumidity2m = "relative_humidity_2m"
            case apparentTemperature = "apparent_temperature"
            case precipitation
            case weatherCode = "weather_code"
            case windSpeed10m = "wind_speed_10m"
            case isDay = "is_day"
        }
    }

    struct HourlyForecast: Decodable {
        let time: [String]?
        let precipitationProbability: [Double?]?

        enum CodingKeys: String, CodingKey {
            case time
            case precipitationProbability = "precipitation_probability"
        }
    }
}
