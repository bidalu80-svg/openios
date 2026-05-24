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

    private init() {}

    func currentWeather() async throws -> LocalWeatherSnapshot {
        let manager = LocationManager.shared
        if !manager.isLocationEnabled {
            manager.isLocationEnabled = true
            manager.requestPermissionAndStart()
        } else {
            manager.requestPermissionAndStart()
        }

        guard let location = manager.cachedLocation else {
            throw LocalWeatherError.locationUnavailable
        }

        do {
            let weather = try await weatherService.weather(for: location)
            let current = weather.currentWeather
            let chance = weather.hourlyForecast.first?.precipitationChance
            let attribution = try weatherService.attribution
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
}
