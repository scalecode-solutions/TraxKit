import Foundation
import CoreLocation

/// Monitors the user's own saved places as `CLCircularRegion`s and publishes a
/// `transition` (enter/leave) when a boundary is crossed — the OwnTracks
/// device-side-geofencing model: the phone decides, the server just records +
/// fans out. iOS wakes the app on a crossing even when backgrounded, so this
/// keeps working on a drive.
///
/// iOS caps an app at 20 monitored regions, so when there are more places (own +
/// shared "our spots"), we monitor the **nearest 20 to the user** and re-rotate
/// as they move — the OwnTracks / Clingy strategy. Far-away places get picked up
/// when you travel toward them.
@MainActor
public final class TraxGeofenceMonitor: NSObject {
    /// iOS hard limit on monitored regions per app.
    private static let maxRegions = 20

    private let manager = CLLocationManager()
    private let onTransition: @Sendable (_ placeID: UUID, _ event: String) async -> Void

    public init(onTransition: @escaping @Sendable (_ placeID: UUID, _ event: String) async -> Void) {
        self.onTransition = onTransition
        super.init()
        manager.delegate = self
    }

    /// Reconcile monitored regions to `places`. Adds new ones, drops removed/edited
    /// ones, re-registers a place whose center/radius changed. When over the
    /// 20-region cap, monitors the nearest 20 to `around` (the user's location) and
    /// logs the overflow rather than silently dropping.
    public func sync(places: [PlaceEntity], around: CLLocationCoordinate2D? = nil) {
        let s = manager.authorizationStatus
        guard s == .authorizedAlways || s == .authorizedWhenInUse else { return }

        let wanted = nearest(places, to: around ?? manager.location?.coordinate)
        if places.count > Self.maxRegions {
            print("TraxGeofenceMonitor: \(places.count) places > 20-region cap; monitoring nearest \(Self.maxRegions)")
        }

        let wantedByID = Dictionary(uniqueKeysWithValues: wanted.map { ($0.id.uuidString, $0) })
        let monitored = manager.monitoredRegions.compactMap { $0 as? CLCircularRegion }

        // Stop regions no longer wanted, or whose geometry changed.
        for region in monitored {
            if let p = wantedByID[region.identifier] {
                if region.center.latitude != p.lat || region.center.longitude != p.lng
                    || region.radius != CLLocationDistance(p.radiusM) {
                    manager.stopMonitoring(for: region) // changed → re-add below
                }
            } else {
                manager.stopMonitoring(for: region)     // gone
            }
        }

        // Start regions not already monitored.
        let monitoredIDs = Set(manager.monitoredRegions.map(\.identifier))
        for p in wanted where !monitoredIDs.contains(p.id.uuidString) {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng),
                radius: CLLocationDistance(p.radiusM), identifier: p.id.uuidString)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
    }

    /// The nearest `maxRegions` places to `coord` (closest geofences win the
    /// limited slots). Returns all when under the cap; falls back to list order
    /// when we have no location to sort by.
    private func nearest(_ places: [PlaceEntity], to coord: CLLocationCoordinate2D?) -> [PlaceEntity] {
        guard places.count > Self.maxRegions else { return places }
        guard let coord else { return Array(places.prefix(Self.maxRegions)) }
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return places
            .sorted { a, b in
                here.distance(from: CLLocation(latitude: a.lat, longitude: a.lng))
                    < here.distance(from: CLLocation(latitude: b.lat, longitude: b.lng))
            }
            .prefix(Self.maxRegions)
            .map { $0 }
    }

    public func stopAll() {
        for region in manager.monitoredRegions { manager.stopMonitoring(for: region) }
    }

    private func emit(_ regionID: String, _ event: String) {
        guard let id = UUID(uuidString: regionID) else { return }
        Task { await onTransition(id, event) }
    }
}

extension TraxGeofenceMonitor: CLLocationManagerDelegate {
    public nonisolated func locationManager(_ m: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor [weak self] in self?.emit(id, "enter") }
    }
    public nonisolated func locationManager(_ m: CLLocationManager, didExitRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor [weak self] in self?.emit(id, "leave") }
    }
}
