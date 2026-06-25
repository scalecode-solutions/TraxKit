import Foundation
import CoreLocation
import CoreMotion
import UIKit
import TraxKit

/// TraxLab's device location engine — the host side of `TraxLocationHost`. Owns the
/// single `CLLocationManager` + the rolling-20 geofence + motion/battery, and feeds
/// enriched fixes + crossings to the kit through the seam. This is the dev-host
/// prototype of what real Clingy's kept-Tangle LocationManager/GeofencingService
/// will provide; the kit itself touches no CoreLocation.
@MainActor
final class TraxLabLocationEngine: NSObject, TraxLocationHost, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let motionMgr = CMMotionActivityManager()
    private var motion: String?
    private var demand: TraxTrackingDemand = .off
    private var regions: [UUID: TraxRegion] = [:]

    private var latestFix: TraxFix?
    private var fixContinuation: AsyncStream<TraxFix>.Continuation?
    private var transitionContinuation: AsyncStream<TraxTransition>.Continuation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.pausesLocationUpdatesAutomatically = false
        UIDevice.current.isBatteryMonitoringEnabled = true
        startMotion()
    }

    // MARK: - TraxLocationHost

    var currentFix: TraxFix? { latestFix }

    func fixStream() -> AsyncStream<TraxFix> {
        AsyncStream { continuation in self.fixContinuation = continuation }
    }

    func transitionStream() -> AsyncStream<TraxTransition> {
        AsyncStream { continuation in self.transitionContinuation = continuation }
    }

    var authorization: TraxLocationAuth {
        switch manager.authorizationStatus {
        case .authorizedAlways:        .always
        case .authorizedWhenInUse:     .whenInUse
        case .denied, .restricted:     .denied
        default:                       .notDetermined
        }
    }

    func requestLocationAccess() {
        switch manager.authorizationStatus {
        case .notDetermined:       manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    func setMonitoredRegions(_ regions: [TraxRegion]) {
        self.regions = Dictionary(uniqueKeysWithValues: regions.map { ($0.placeID, $0) })
        reconcileRegions()
    }

    func setDesiredTracking(_ demand: TraxTrackingDemand) {
        guard demand != self.demand else { return }
        self.demand = demand
        applyDemand()
    }

    // MARK: - Hardware

    private func applyDemand() {
        let s = manager.authorizationStatus
        guard s == .authorizedAlways || s == .authorizedWhenInUse else { return }
        switch demand {
        case .off, .significant:
            manager.stopUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()   // still feed the self-dot
        case .continuous:
            manager.stopMonitoringSignificantLocationChanges()
            manager.allowsBackgroundLocationUpdates = (s == .authorizedAlways)
            manager.startUpdatingLocation()
        }
    }

    /// Rolling-20 nearest to the current fix (the single-owner region budget).
    private func reconcileRegions() {
        let s = manager.authorizationStatus
        guard s == .authorizedAlways || s == .authorizedWhenInUse else { return }
        let wanted = nearest20(Array(regions.values), to: latestFix)
        let wantedIDs = Set(wanted.map { $0.placeID.uuidString })
        for r in manager.monitoredRegions where !wantedIDs.contains(r.identifier) {
            manager.stopMonitoring(for: r)
        }
        let monitoredIDs = Set(manager.monitoredRegions.map(\.identifier))
        for region in wanted where !monitoredIDs.contains(region.placeID.uuidString) {
            let cl = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: region.lat, longitude: region.lng),
                radius: region.radiusMeters, identifier: region.placeID.uuidString)
            cl.notifyOnEntry = true; cl.notifyOnExit = true
            manager.startMonitoring(for: cl)
        }
    }

    private func nearest20(_ regions: [TraxRegion], to fix: TraxFix?) -> [TraxRegion] {
        guard regions.count > 20 else { return regions }
        guard let fix else { return Array(regions.prefix(20)) }
        let here = CLLocation(latitude: fix.lat, longitude: fix.lng)
        return regions.sorted {
            here.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lng))
                < here.distance(from: CLLocation(latitude: $1.lat, longitude: $1.lng))
        }.prefix(20).map { $0 }
    }

    private func startMotion() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        motionMgr.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            self.motion = Self.classify(activity)
        }
    }

    nonisolated private static func classify(_ a: CMMotionActivity) -> String? {
        if a.confidence == .low { return nil }
        if a.automotive { return "automotive" }
        if a.cycling    { return "cycling" }
        if a.running    { return "running" }
        if a.walking    { return "walking" }
        if a.stationary { return "stationary" }
        return nil
    }

    private func makeFix(_ loc: CLLocation) -> TraxFix {
        let lvl = UIDevice.current.batteryLevel
        let battery = lvl >= 0 ? Int((lvl * 100).rounded()) : nil
        let charging: Bool? = switch UIDevice.current.batteryState {
            case .charging, .full: true
            case .unplugged:       false
            default:               nil
        }
        return TraxFix(
            lat: loc.coordinate.latitude, lng: loc.coordinate.longitude,
            horizontalAccuracy: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil,
            altitude: loc.verticalAccuracy >= 0 ? loc.altitude : nil,
            speed: loc.speed >= 0 ? loc.speed : nil,
            course: loc.course >= 0 ? loc.course : nil,
            motion: motion, batteryLevel: battery, batteryCharging: charging,
            timestamp: loc.timestamp)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            let fix = self.makeFix(loc)
            self.latestFix = fix
            self.fixContinuation?.yield(fix)
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didEnterRegion region: CLRegion) {
        emit(region.identifier, .enter)
    }
    nonisolated func locationManager(_ m: CLLocationManager, didExitRegion region: CLRegion) {
        emit(region.identifier, .leave)
    }
    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in self.applyDemand(); self.reconcileRegions() }
    }

    nonisolated private func emit(_ regionID: String, _ event: TraxEvent) {
        guard let id = UUID(uuidString: regionID) else { return }
        Task { @MainActor in
            self.transitionContinuation?.yield(TraxTransition(placeID: id, event: event, timestamp: Date()))
        }
    }
}
