import Foundation
import CoreLocation

/// Monitors the user's own saved places as `CLCircularRegion`s and publishes a
/// `transition` (enter/leave) when a boundary is crossed — the OwnTracks
/// device-side-geofencing model: the phone decides, the server just records +
/// fans out. iOS wakes the app on a crossing even when backgrounded, so this
/// keeps working on a drive.
///
/// v1 monitors up to iOS's 20-region cap directly (no proximity rotation) —
/// real users have far fewer than 20 places; rotation is a later refinement.
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

    /// Reconcile monitored regions to `places` (the user's own). Adds new ones,
    /// drops removed/edited ones, and re-registers a place whose center/radius
    /// changed. Caps at 20 (logs the overflow rather than silently dropping).
    public func sync(places: [PlaceEntity]) {
        let s = manager.authorizationStatus
        guard s == .authorizedAlways || s == .authorizedWhenInUse else { return }

        let wanted = Array(places.prefix(Self.maxRegions))
        if places.count > Self.maxRegions {
            // No silent cap — see DESIGN.md "no silent truncation".
            print("TraxGeofenceMonitor: \(places.count) places > 20-region cap; monitoring nearest-by-list first 20")
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
