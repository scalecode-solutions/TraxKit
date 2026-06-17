import SwiftUI
import CoreLocation

/// Shared reverse-geocode cache → short human labels for rows + detail. Coordinate-
/// rounded so we geocode once per area and reuse across self + every sharer (same
/// waste-avoidance as the weather cache). Precision-aware: `exact` resolves to
/// street level; coarse coords resolve to city only, so an approx/place sharer
/// never gets reverse-geocoded to a street.
@MainActor
@Observable
public final class TraxGeocoder {
    private var cache: [String: String] = [:]
    private var inflight: Set<String> = []
    private let geocoder = CLGeocoder()

    public init() {}

    private func key(_ lat: Double, _ lng: Double, exact: Bool) -> String {
        let f = exact ? 1000.0 : 100.0   // ~110m buckets exact, ~1.1km coarse
        return "\(Int(lat * f)),\(Int(lng * f)):\(exact)"
    }

    /// Cached label if resolved (observed — rows re-render when it fills in).
    public func cachedLabel(latitude: Double, longitude: Double, exact: Bool) -> String? {
        cache[key(latitude, longitude, exact: exact)]
    }

    /// Resolve-if-missing for a coordinate. Coalesces per region.
    public func resolve(latitude: Double, longitude: Double, exact: Bool) async {
        let k = key(latitude, longitude, exact: exact)
        if cache[k] != nil || inflight.contains(k) { return }
        inflight.insert(k)
        defer { inflight.remove(k) }
        let placemarks = try? await geocoder.reverseGeocodeLocation(
            CLLocation(latitude: latitude, longitude: longitude))
        guard let p = placemarks?.first else { return }
        cache[k] = Self.label(from: p, exact: exact)
    }

    private static func label(from p: CLPlacemark, exact: Bool) -> String {
        let city = [p.locality, p.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        if exact {
            let street = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
            if !street.isEmpty {
                return p.locality.map { "\(street), \($0)" } ?? street
            }
        }
        if !city.isEmpty { return city }
        return p.name ?? "Nearby"
    }
}
