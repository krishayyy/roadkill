import CoreLocation
import Foundation
import WeatherKit

enum SimpleCondition {
    case clear, cloudy, rain, snow, fog
}

struct WeatherSnapshot {
    let temperatureF: Double
    let condition: SimpleCondition
    let conditionLabel: String
    let visibilityMeters: Double
}

@Observable
final class WeatherManager {
    private let service = WeatherService.shared
    var current: WeatherSnapshot?
    var lastError: String?

    func refresh(for location: CLLocation) async {
        do {
            let weather = try await service.weather(for: location)
            let condition = weather.currentWeather.condition
            current = WeatherSnapshot(
                temperatureF: weather.currentWeather.temperature.converted(to: .fahrenheit).value,
                condition: mapCondition(condition),
                conditionLabel: label(for: condition),
                visibilityMeters: weather.currentWeather.visibility.converted(to: .meters).value
            )
            lastError = nil
        } catch {
            // WeatherKit requires the capability to be enabled on the App ID
            // in the Apple Developer portal, plus a signed build. Until then,
            // fall back to a deterministic mock so the risk engine still has
            // something to react to.
            lastError = error.localizedDescription
            current = mockWeather(for: location)
        }
    }

    private func mapCondition(_ condition: WeatherCondition) -> SimpleCondition {
        switch condition {
        case .foggy, .haze, .smoky: return .fog
        case .rain, .drizzle, .heavyRain, .thunderstorms, .isolatedThunderstorms, .strongStorms: return .rain
        case .snow, .heavySnow, .blizzard, .flurries, .sleet, .wintryMix: return .snow
        case .cloudy, .mostlyCloudy, .partlyCloudy: return .cloudy
        default: return .clear
        }
    }

    private func label(for condition: WeatherCondition) -> String {
        condition.description
    }

    /// Deterministic mock keyed off location + hour, purely so the demo has
    /// live-looking weather before WeatherKit is fully provisioned.
    private func mockWeather(for location: CLLocation) -> WeatherSnapshot {
        let hour = Calendar.current.component(.hour, from: Date())
        let seed = Int(location.coordinate.latitude * 100) + hour
        switch seed % 5 {
        case 0: return WeatherSnapshot(temperatureF: 38, condition: .fog, conditionLabel: "Fog", visibilityMeters: 400)
        case 1: return WeatherSnapshot(temperatureF: 45, condition: .rain, conditionLabel: "Light Rain", visibilityMeters: 3000)
        case 2: return WeatherSnapshot(temperatureF: 29, condition: .snow, conditionLabel: "Snow", visibilityMeters: 800)
        case 3: return WeatherSnapshot(temperatureF: 52, condition: .cloudy, conditionLabel: "Cloudy", visibilityMeters: 8000)
        default: return WeatherSnapshot(temperatureF: 61, condition: .clear, conditionLabel: "Clear", visibilityMeters: 10000)
        }
    }
}
