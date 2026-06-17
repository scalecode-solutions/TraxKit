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
}

/// The weather source. The host can inject its own (a shared cache, Open-Meteo,
/// …); TraxKit ships a WeatherKit default. Mirrors PulseKit's resolver seam.
public protocol TraxWeatherProviding: Sendable {
    func current(latitude: Double, longitude: Double) async -> TraxWeather?
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
