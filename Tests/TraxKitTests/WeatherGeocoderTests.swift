import Foundation
import Testing
import SwiftUI
import UIKit
@testable import TraxKit

/// A weather provider that records what it was asked for.
final class RecordingWeather: TraxWeatherProviding, @unchecked Sendable {
    var asked: [(Double, Double)] = []
    func current(latitude: Double, longitude: Double) async -> TraxWeather? {
        asked.append((latitude, longitude))
        return TraxWeather(temperatureC: 20, condition: "Clear", symbolName: "sun.max")
    }
}

@MainActor
@Suite struct WeatherStoreTests {
    final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_800_000_000) }

    /// Only the bucket's center leaves the device, and negative coordinates
    /// bucket like positive ones (floor, not truncation).
    @Test func providerGetsTheBucketCenterNotThePerson() async {
        let p = RecordingWeather()
        let store = TraxWeatherStore(provider: p, now: Date.init)
        await store.refresh(latitude: 37.33182, longitude: -122.03118)
        let (lat, lng) = try! #require(p.asked.first)
        #expect(abs(lat - 37.35) < 1e-9)
        #expect(abs(lng - (-122.05)) < 1e-9)
        #expect(TraxWeatherStore.regionKey(latitude: 0.05, longitude: -0.05) == "0,-1")
    }

    /// Past the TTL the old value still shows while a refetch runs; only past
    /// the stale limit does it disappear.
    @Test func staleValueShowsWhileRefetching() async {
        let p = RecordingWeather(), clock = Clock()
        let store = TraxWeatherStore(provider: p, now: { clock.t })
        await store.refresh(latitude: 1, longitude: 1)
        clock.t += TraxWeatherStore.ttl + 60
        #expect(store.cached(latitude: 1, longitude: 1) != nil, "a badge went blank after the TTL")
        await store.refresh(latitude: 1, longitude: 1)
        #expect(p.asked.count == 2, "no refetch after the TTL")
        clock.t += TraxWeatherStore.maxStale + 60
        #expect(store.cached(latitude: 1, longitude: 1) == nil)
    }

    @Test func freshValueIsntRefetched() async {
        let p = RecordingWeather()
        let store = TraxWeatherStore(provider: p, now: Date.init)
        await store.refresh(latitude: 1, longitude: 1)
        await store.refresh(latitude: 1.01, longitude: 1.01)   // same bucket
        #expect(p.asked.count == 1)
    }
}

/// A geocoder that records concurrency and can fail.
actor FakeGeocoder: TraxReverseGeocoding {
    var running = 0, maxRunning = 0, calls = 0
    var asked: [(Double, Double)] = []
    var failuresLeft = 0
    func failNext(_ n: Int) { failuresLeft = n }
    func reverse(latitude: Double, longitude: Double) async throws -> TraxGeocodeResult? {
        running += 1; maxRunning = max(maxRunning, running); calls += 1
        asked.append((latitude, longitude))
        try? await Task.sleep(for: .milliseconds(5))
        running -= 1
        if failuresLeft > 0 { failuresLeft -= 1; throw URLError(.timedOut) }
        return TraxGeocodeResult(street: "1 Main St, Springfield", city: "Springfield, IL", name: nil)
    }
}

@MainActor
@Suite struct GeocoderTests {
    @Test func lookupsRunOneAtATimeAndCoalesce() async {
        let g = FakeGeocoder()
        let geo = TraxGeocoder(geocoder: g, spacing: .milliseconds(1))
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<6 {
                group.addTask { await geo.resolve(latitude: 10 + Double(i), longitude: 10, exact: true) }
                group.addTask { await geo.resolve(latitude: 10 + Double(i), longitude: 10, exact: true) }   // duplicate
            }
        }
        #expect(await g.maxRunning == 1, "lookups overlapped")
        #expect(await g.calls == 6, "duplicates weren't coalesced")
    }

    @Test func onlyTheBucketCenterIsSentAndLabelsFollowPrecision() async {
        let g = FakeGeocoder()
        let geo = TraxGeocoder(geocoder: g, spacing: .milliseconds(1))
        await geo.resolve(latitude: 37.33182, longitude: -122.03118, exact: false)
        let (lat, lng) = try! #require(await g.asked.first)
        #expect(abs(lat - 37.335) < 1e-9 && abs(lng - (-122.035)) < 1e-9)
        #expect(geo.cachedLabel(latitude: 37.33182, longitude: -122.03118, exact: false) == "Springfield, IL")
        await geo.resolve(latitude: 37.33182, longitude: -122.03118, exact: true)
        #expect(geo.cachedLabel(latitude: 37.33182, longitude: -122.03118, exact: true) == "1 Main St, Springfield")
    }

    @Test func aFailureBacksOffAndALaterTrySucceeds() async {
        let g = FakeGeocoder()
        await g.failNext(1)
        let geo = TraxGeocoder(geocoder: g, spacing: .milliseconds(1), maxBackoff: .milliseconds(20))
        await geo.resolve(latitude: 1, longitude: 1, exact: false)
        #expect(geo.cachedLabel(latitude: 1, longitude: 1, exact: false) == nil)
        await geo.resolve(latitude: 1, longitude: 1, exact: false)   // not stuck in-flight; retried after the backoff
        #expect(geo.cachedLabel(latitude: 1, longitude: 1, exact: false) == "Springfield, IL")
    }

    @Test func theCacheIsCapped() async {
        let g = FakeGeocoder()
        let geo = TraxGeocoder(geocoder: g, spacing: .zero)
        for i in 0..<(TraxGeocoder.cap + 5) {
            await geo.resolve(latitude: Double(i), longitude: 0, exact: false)
        }
        #expect(geo.cachedLabel(latitude: 0, longitude: 0, exact: false) == nil, "the oldest wasn't evicted")
        #expect(geo.cachedLabel(latitude: Double(TraxGeocoder.cap + 4), longitude: 0, exact: false) != nil)
    }
}

/// The badge on screen: it fetches for itself, also when it shows nothing
/// until there's weather (the person card's quiet badge and the plain one,
/// cold cache). Hosted in a window, so the view's own `.task` is what runs:
/// removing it fails all three.
@MainActor
@Suite struct WeatherBadgeFetchTests {
    func fetches(_ badge: TraxWeatherBadge, provider p: RecordingWeather) async -> Bool {
        let host = UIHostingController(rootView: badge)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<300 where p.asked.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !p.asked.isEmpty
    }

    @Test func theExplainingBadgeFetches() async {   // the harness itself
        let p = RecordingWeather()
        let store = TraxWeatherStore(provider: p, now: Date.init)
        #expect(await fetches(TraxWeatherBadge(store: store, latitude: 30, longitude: -90, showCondition: true), provider: p))
    }

    @Test func thePlainBadgeFetchesFromAColdCache() async {
        let p = RecordingWeather()
        let store = TraxWeatherStore(provider: p, now: Date.init)
        #expect(await fetches(TraxWeatherBadge(store: store, latitude: 30, longitude: -90), provider: p))
    }

    @Test func theQuietBadgeFetchesFromAColdCache() async {
        let p = RecordingWeather()
        let store = TraxWeatherStore(provider: p, now: Date.init)
        #expect(await fetches(TraxWeatherBadge(store: store, latitude: 30, longitude: -90, showCondition: true)
            .quietWhenEmpty(), provider: p))
    }
}
