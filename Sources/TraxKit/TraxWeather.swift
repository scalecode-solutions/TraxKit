import SwiftUI
import CoreLocation
import WeatherKit

/// Current conditions, provider-agnostic. Temperature stored canonical (Celsius);
/// formatted to the viewer's locale at render.
public struct TraxWeather: Sendable, Hashable {
    public let temperatureC: Double
    public let feelsLikeC: Double?
    public let highC: Double?
    public let lowC: Double?
    public let condition: String   // "Rainy"
    public let symbolName: String  // SF Symbol

    public init(temperatureC: Double, feelsLikeC: Double? = nil, highC: Double? = nil,
                lowC: Double? = nil, condition: String, symbolName: String) {
        self.temperatureC = temperatureC; self.feelsLikeC = feelsLikeC
        self.highC = highC; self.lowC = lowC; self.condition = condition; self.symbolName = symbolName
    }

    /// Locale-formatted temperature, e.g. "54°".
    public static func temp(_ celsius: Double) -> String {
        let useF = Locale.current.measurementSystem == .us
        let t = useF ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(t.rounded()))°"
    }
    public var tempText: String { Self.temp(temperatureC) }

    /// Locale-formatted wind speed (mph for imprecise/US locales, else km/h).
    public static func wind(_ kmh: Double) -> String {
        let imperial = Locale.current.measurementSystem != .metric
        return imperial ? "\(Int((kmh * 0.621371).rounded())) mph" : "\(Int(kmh.rounded())) km/h"
    }
    /// Locale-formatted distance (visibility), mi vs km.
    public static func distance(_ km: Double) -> String {
        let imperial = Locale.current.measurementSystem != .metric
        return imperial ? String(format: "%.0f mi", km * 0.621371) : String(format: "%.0f km", km)
    }
}

/// One hour of forecast (the 24-hour strip).
public struct TraxWeatherHour: Sendable, Hashable, Identifiable {
    public let date: Date
    public let temperatureC: Double
    public let symbolName: String
    public let precipChance: Double   // 0…1
    public var id: Date { date }
    public init(date: Date, temperatureC: Double, symbolName: String, precipChance: Double) {
        self.date = date; self.temperatureC = temperatureC
        self.symbolName = symbolName; self.precipChance = precipChance
    }
}

/// One day of forecast (the 10-day list).
public struct TraxWeatherDay: Sendable, Hashable, Identifiable {
    public let date: Date
    public let highC: Double
    public let lowC: Double
    public let symbolName: String
    public let precipChance: Double   // 0…1
    public var id: Date { date }
    public init(date: Date, highC: Double, lowC: Double, symbolName: String, precipChance: Double) {
        self.date = date; self.highC = highC; self.lowC = lowC
        self.symbolName = symbolName; self.precipChance = precipChance
    }
}

/// The full forecast for the detail screen — current conditions plus hourly,
/// daily, and the metric panel. Built from one provider call.
public struct TraxWeatherDetail: Sendable, Hashable {
    public let current: TraxWeather
    public let hourly: [TraxWeatherHour]   // next ~24h
    public let daily: [TraxWeatherDay]     // ~10 days
    public let humidity: Double?           // 0…1
    public let uvIndex: Int?
    public let uvCategory: String?
    public let windSpeedKmh: Double?
    public let windDirection: String?      // "NW"
    public let pressureHpa: Double?
    public let visibilityKm: Double?
    public let sunrise: Date?
    public let sunset: Date?
    public let precipSummary: String?      // minute-forecast sentence

    public init(current: TraxWeather, hourly: [TraxWeatherHour], daily: [TraxWeatherDay],
                humidity: Double? = nil, uvIndex: Int? = nil, uvCategory: String? = nil,
                windSpeedKmh: Double? = nil, windDirection: String? = nil,
                pressureHpa: Double? = nil, visibilityKm: Double? = nil,
                sunrise: Date? = nil, sunset: Date? = nil, precipSummary: String? = nil) {
        self.current = current; self.hourly = hourly; self.daily = daily
        self.humidity = humidity; self.uvIndex = uvIndex; self.uvCategory = uvCategory
        self.windSpeedKmh = windSpeedKmh; self.windDirection = windDirection
        self.pressureHpa = pressureHpa; self.visibilityKm = visibilityKm
        self.sunrise = sunrise; self.sunset = sunset; self.precipSummary = precipSummary
    }
}

/// The weather source. The host can inject its own (a shared cache, Open-Meteo,
/// …); TraxKit ships a WeatherKit default. Mirrors PulseKit's resolver seam.
public protocol TraxWeatherProviding: Sendable {
    func current(latitude: Double, longitude: Double) async -> TraxWeather?
    /// Full forecast for the detail screen. Default returns nil (a current-only
    /// provider just won't surface the detail screen).
    func detail(latitude: Double, longitude: Double) async -> TraxWeatherDetail?
}

public extension TraxWeatherProviding {
    func detail(latitude: Double, longitude: Double) async -> TraxWeatherDetail? { nil }
}

/// Default provider: Apple WeatherKit (needs the com.apple.developer.weatherkit
/// entitlement on the host App ID — returns nil gracefully if unavailable).
public struct WeatherKitProvider: TraxWeatherProviding {
    public init() {}
    public func current(latitude: Double, longitude: Double) async -> TraxWeather? {
        do {
            let w = try await WeatherService.shared.weather(for: CLLocation(latitude: latitude, longitude: longitude))
            let c = w.currentWeather
            let today = w.dailyForecast.first
            return TraxWeather(
                temperatureC: c.temperature.converted(to: .celsius).value,
                feelsLikeC: c.apparentTemperature.converted(to: .celsius).value,
                highC: today?.highTemperature.converted(to: .celsius).value,
                lowC: today?.lowTemperature.converted(to: .celsius).value,
                condition: c.condition.description,
                symbolName: c.symbolName)
        } catch {
            return nil
        }
    }

    public func detail(latitude: Double, longitude: Double) async -> TraxWeatherDetail? {
        do {
            let loc = CLLocation(latitude: latitude, longitude: longitude)
            let w = try await WeatherService.shared.weather(for: loc)
            let c = w.currentWeather
            let today = w.dailyForecast.first
            let current = TraxWeather(
                temperatureC: c.temperature.converted(to: .celsius).value,
                feelsLikeC: c.apparentTemperature.converted(to: .celsius).value,
                highC: today?.highTemperature.converted(to: .celsius).value,
                lowC: today?.lowTemperature.converted(to: .celsius).value,
                condition: c.condition.description,
                symbolName: c.symbolName)
            let now = Date()
            let hourly = w.hourlyForecast
                .filter { $0.date >= now }
                .prefix(24)
                .map { TraxWeatherHour(date: $0.date,
                                       temperatureC: $0.temperature.converted(to: .celsius).value,
                                       symbolName: $0.symbolName,
                                       precipChance: $0.precipitationChance) }
            let daily = w.dailyForecast
                .prefix(10)
                .map { TraxWeatherDay(date: $0.date,
                                      highC: $0.highTemperature.converted(to: .celsius).value,
                                      lowC: $0.lowTemperature.converted(to: .celsius).value,
                                      symbolName: $0.symbolName,
                                      precipChance: $0.precipitationChance) }
            return TraxWeatherDetail(
                current: current,
                hourly: Array(hourly),
                daily: Array(daily),
                humidity: c.humidity,
                uvIndex: c.uvIndex.value,
                uvCategory: c.uvIndex.category.description,
                windSpeedKmh: c.wind.speed.converted(to: .kilometersPerHour).value,
                windDirection: c.wind.compassDirection.abbreviation,
                pressureHpa: c.pressure.converted(to: .hectopascals).value,
                visibilityKm: c.visibility.converted(to: .kilometers).value,
                sunrise: today?.sun.sunrise,
                sunset: today?.sun.sunset,
                precipSummary: Self.precipSummary(w.minuteForecast))
        } catch {
            return nil
        }
    }

    /// A one-line "rain starting/ending in N min" summary from the minute forecast.
    private static func precipSummary(_ minute: WeatherKit.Forecast<MinuteWeather>?) -> String? {
        guard let minute else { return nil }
        let pts = Array(minute.prefix(60))
        guard !pts.isEmpty else { return nil }
        let raining = (pts.first?.precipitationIntensity.value ?? 0) > 0
        if raining {
            if let stop = pts.firstIndex(where: { $0.precipitationIntensity.value == 0 }) {
                return "Precipitation ending in \(stop) min"
            }
            return "Precipitation for the next hour"
        } else if let start = pts.firstIndex(where: { $0.precipitationIntensity.value > 0 }) {
            return "Precipitation starting in \(start) min"
        }
        return "No precipitation in the next hour"
    }
}

/// Shared, coordinate-rounded weather cache. One fetch per ~11km region (weather
/// is regional), reused across self + every sharer in that area — the fix for
/// Tangle's per-person fetch waste. 15-minute TTL.
@MainActor
@Observable
public final class TraxWeatherStore {
    private let provider: any TraxWeatherProviding
    private var cache: [String: (w: TraxWeather, at: Date)] = [:]
    private var inflight: Set<String> = []
    private var detailCache: [String: (d: TraxWeatherDetail, at: Date)] = [:]
    private var detailInflight: Set<String> = []
    private let ttl: TimeInterval = 15 * 60

    public init(provider: any TraxWeatherProviding) { self.provider = provider }

    private func key(_ lat: Double, _ lng: Double) -> String {
        // Round to ~0.1° (~11km) — weather doesn't vary block-to-block.
        "\(Int(lat * 10)),\(Int(lng * 10))"
    }

    /// Cached value if fresh (observed — views re-render when the cache fills).
    public func cached(latitude: Double, longitude: Double) -> TraxWeather? {
        let k = key(latitude, longitude)
        if let e = cache[k], Date().timeIntervalSince(e.at) < ttl { return e.w }
        return nil
    }

    /// Fetch-if-stale for a coordinate (call from .task). Coalesces concurrent
    /// requests for the same region.
    public func refresh(latitude: Double, longitude: Double) async {
        let k = key(latitude, longitude)
        if let e = cache[k], Date().timeIntervalSince(e.at) < ttl { return }
        if inflight.contains(k) { return }
        inflight.insert(k)
        let w = await provider.current(latitude: latitude, longitude: longitude)
        inflight.remove(k)
        if let w { cache[k] = (w, Date()) }
    }

    /// Cached full forecast if fresh (observed).
    public func cachedDetail(latitude: Double, longitude: Double) -> TraxWeatherDetail? {
        let k = key(latitude, longitude)
        if let e = detailCache[k], Date().timeIntervalSince(e.at) < ttl { return e.d }
        return nil
    }

    /// Fetch-if-stale full forecast for a coordinate. Coalesces per region. Also
    /// warms the lightweight current-conditions cache from the same fetch.
    public func refreshDetail(latitude: Double, longitude: Double) async {
        let k = key(latitude, longitude)
        if let e = detailCache[k], Date().timeIntervalSince(e.at) < ttl { return }
        if detailInflight.contains(k) { return }
        detailInflight.insert(k)
        let d = await provider.detail(latitude: latitude, longitude: longitude)
        detailInflight.remove(k)
        if let d {
            let now = Date()
            detailCache[k] = (d, now)
            cache[k] = (d.current, now)   // share the fetch with the badge cache
        }
    }
}

/// A compact current-conditions badge for a coordinate: icon + temp (+ optional
/// condition). Renders nothing until weather is available (graceful).
public struct TraxWeatherBadge: View {
    let store: TraxWeatherStore
    let latitude: Double
    let longitude: Double
    var showCondition = false

    public init(store: TraxWeatherStore, latitude: Double, longitude: Double, showCondition: Bool = false) {
        self.store = store; self.latitude = latitude; self.longitude = longitude; self.showCondition = showCondition
    }

    public var body: some View {
        Group {
            if let w = store.cached(latitude: latitude, longitude: longitude) {
                HStack(spacing: 5) {
                    Image(systemName: w.symbolName).symbolRenderingMode(.multicolor)
                    Text(w.tempText)
                    if showCondition { Text(w.condition).foregroundStyle(.secondary) }
                }
            }
        }
        .task(id: "\(Int(latitude * 10)),\(Int(longitude * 10))") {
            await store.refresh(latitude: latitude, longitude: longitude)
        }
    }
}
