import SwiftUI
import CoreLocation
import MapKit

/// What a reverse geocode returns, reduced to what the labels use.
struct TraxGeocodeResult: Sendable, Equatable {
    var street: String?     // MapKit's short address, e.g. "1 Main St, Springfield"
    var city: String?       // e.g. "Springfield, IL"
    var name: String?
}

/// Reverse geocoding, behind a seam so tests don't call Apple.
protocol TraxReverseGeocoding: Sendable {
    func reverse(latitude: Double, longitude: Double) async throws -> TraxGeocodeResult?
}

/// MapKit's reverse geocoder (iOS 26: MKReverseGeocodingRequest replaces the
/// deprecated CLGeocoder).
struct MapKitReverseGeocoder: TraxReverseGeocoding {
    func reverse(latitude: Double, longitude: Double) async throws -> TraxGeocodeResult? {
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude))
        else { return nil }
        guard let item = try await request.mapItems.first else { return nil }
        let reps = item.addressRepresentations
        return TraxGeocodeResult(street: item.address?.shortAddress, city: reps?.cityWithContext ?? reps?.cityName,
                                 name: item.name)
    }
}

/// Shared reverse-geocode cache → short human labels for rows + detail.
///
/// - Bucketed: one lookup per area, reused across me and every sharer there,
///   and only the bucket's center is sent to Apple (exact: ~110 m, else ~1.1 km),
///   never a person's exact coordinate.
/// - Precision-aware: `exact` resolves to street level; coarse coordinates to
///   the city only, so an approx/place sharer is never named to a street.
/// - Polite to Apple's rate limit: lookups run one at a time, at least
///   `spacing` apart, backing off after a failure; the cache is capped.
@MainActor
@Observable
public final class TraxGeocoder {
    private var cache: [String: String] = [:]
    private var order: [String] = []          // insertion order, for the cap
    private var inflight: Set<String> = []
    private let geocoder: any TraxReverseGeocoding
    private let spacing: Duration
    private let maxBackoff: Duration
    private var chain: Task<Void, Never>?      // lookups run one after another
    private var nextAllowed = ContinuousClock.now
    private var backoff: Duration?
    static let cap = 200

    public convenience init() {
        self.init(geocoder: MapKitReverseGeocoder())
    }

    init(geocoder: any TraxReverseGeocoding, spacing: Duration = .seconds(1), maxBackoff: Duration = .seconds(60)) {
        self.geocoder = geocoder
        self.spacing = spacing
        self.maxBackoff = maxBackoff
    }

    /// Exact labels are looked up at the center of a ~110 m cell, not the
    /// person's point: the street can be off by a block at a cell's edge, the
    /// price of never sending Apple an exact coordinate.
    static func step(exact: Bool) -> Double { exact ? 0.001 : 0.01 }   // ~110 m / ~1.1 km
    static func cell(_ v: Double, exact: Bool) -> Int { Int((v / step(exact: exact)).rounded(.down)) }
    static func center(_ v: Double, exact: Bool) -> Double {
        (Double(cell(v, exact: exact)) + 0.5) * step(exact: exact)
    }

    private func key(_ lat: Double, _ lng: Double, exact: Bool) -> String {
        "\(Self.cell(lat, exact: exact)),\(Self.cell(lng, exact: exact)):\(exact)"
    }

    /// Cached label if resolved (observed — rows re-render when it fills in).
    public func cachedLabel(latitude: Double, longitude: Double, exact: Bool) -> String? {
        cache[key(latitude, longitude, exact: exact)]
    }

    /// Resolve-if-missing for a coordinate. Coalesces per area; queued behind
    /// any lookup already running.
    public func resolve(latitude: Double, longitude: Double, exact: Bool) async {
        let k = key(latitude, longitude, exact: exact)
        if cache[k] != nil || inflight.contains(k) { return }
        inflight.insert(k)
        let lat = Self.center(latitude, exact: exact), lng = Self.center(longitude, exact: exact)
        let previous = chain
        let mine = Task { [weak self] in
            await previous?.value
            await self?.lookUp(k, lat, lng, exact: exact)
        }
        chain = mine
        await mine.value
    }

    private func lookUp(_ k: String, _ lat: Double, _ lng: Double, exact: Bool) async {
        defer { inflight.remove(k) }
        let wait = nextAllowed - ContinuousClock.now
        if wait > .zero { try? await Task.sleep(for: wait) }
        do {
            let r = try await geocoder.reverse(latitude: lat, longitude: lng)
            backoff = nil
            nextAllowed = ContinuousClock.now + spacing
            if let r { store(k, Self.label(from: r, exact: exact)) }
        } catch {
            // Throttled or offline: wait longer before the next lookup.
            let next = min((backoff ?? spacing) * 2, maxBackoff)
            backoff = next
            nextAllowed = ContinuousClock.now + next
        }
    }

    private func store(_ k: String, _ label: String) {
        if cache[k] == nil { order.append(k) }
        cache[k] = label
        if order.count > Self.cap {
            let drop = order.prefix(order.count - Self.cap)
            for old in drop { cache[old] = nil }
            order.removeFirst(drop.count)
        }
    }

    static func label(from r: TraxGeocodeResult, exact: Bool) -> String {
        // MapKit's short address already reads "1 Main St, Springfield".
        if exact, let street = r.street, !street.isEmpty { return street }
        if let city = r.city, !city.isEmpty { return city }
        return r.name ?? "Nearby"
    }
}
