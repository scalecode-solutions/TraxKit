import Foundation
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

/// Acquires device location and POSTs fixes to mvTrax (the `/v0/track` producer).
/// The CoreLocation patterns are lifted from OwnTracks' Move mode — the proven
/// essentials, none of the 10-year-old complexity:
///   • continuous `startUpdatingLocation` + `allowsBackgroundLocationUpdates` +
///     `pausesLocationUpdatesAutomatically = false` → keeps delivering on a drive
///     with the app backgrounded (the freeway case), no clever wake needed;
///   • publish throttle (default 15s, like Tangle) so we don't spam the server
///     with every raw fix;
///   • a heartbeat so a stationary device still refreshes its head occasionally.
/// Region monitoring (→ `transition` events) is intentionally deferred until the
/// server endpoint exists — see mvTrax/docs/DESIGN.md.
///
/// `@MainActor`: CLLocationManager is created/used on main; the delegate hops
/// back to main. The send closure is `async` and hops off-main inside the
/// transport.
@MainActor
public final class TraxLocationProducer: NSObject {
    /// Minimum seconds between published fixes (OwnTracks `minTime`; Tangle 15s).
    public var minInterval: TimeInterval = 15
    /// Heartbeat: republish at least this often even when stationary.
    public var heartbeat: TimeInterval = 60
    /// Minimum metres moved to publish before `minInterval` elapses (0 = time-only).
    public var minDistance: CLLocationDistance = 0

    public private(set) var isRunning = false
    public private(set) var lastError: String?

    private let manager = CLLocationManager()
    private let send: @Sendable (TrackBody) async -> Void
    private var lastSentAt: Date?
    private var lastSentLocation: CLLocation?
    private var heartbeatTimer: Timer?

    /// `send` receives each throttled fix as a ready-to-POST `TrackBody`. Wire it
    /// to `TraxSync.track`.
    public init(send: @escaping @Sendable (TrackBody) async -> Void) {
        self.send = send
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone   // we throttle, not CL
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Request authorization and begin producing. Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        // When-in-use first; escalate to Always for background drives. iOS shows
        // the right prompt based on the Info.plist usage strings.
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
        beginUpdates()
        startHeartbeat()
    }

    public func stop() {
        isRunning = false
        manager.stopUpdatingLocation()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// Whether the HOST app declares the `location` background mode. CoreLocation
    /// *crashes* (asserts) if `allowsBackgroundLocationUpdates = true` is set
    /// without it, so the SPM must never assume the host opted in.
    private var hostAllowsBackground: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?
            .contains("location") ?? false
    }

    private func beginUpdates() {
        let s = manager.authorizationStatus
        guard s == .authorizedWhenInUse || s == .authorizedAlways else { return }
        // Background delivery is only legal once Always-authorized AND the host
        // declared the location background mode — otherwise CL asserts.
        manager.allowsBackgroundLocationUpdates = (s == .authorizedAlways) && hostAllowsBackground
        if hostAllowsBackground { manager.showsBackgroundLocationIndicator = true }
        manager.startUpdatingLocation()
    }

    /// Heartbeat: if the device is stationary (no CL updates), still republish the
    /// last known fix every `heartbeat` so the viewer's head doesn't go stale.
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let t = Timer(timeInterval: heartbeat, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeatTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
    }

    private func heartbeatTick() {
        guard isRunning, let loc = manager.location else { return }
        publish(loc, force: true)
    }

    /// Throttle + publish. Sends when `minInterval` has elapsed since the last
    /// send (or `minDistance` crossed), or when `force` (heartbeat).
    private func publish(_ location: CLLocation, force: Bool = false) {
        let now = Date()
        if !force {
            if let last = lastSentAt, now.timeIntervalSince(last) < minInterval {
                if minDistance <= 0 { return }
                if let lastLoc = lastSentLocation,
                   location.distance(from: lastLoc) < minDistance { return }
            }
        }
        lastSentAt = now
        lastSentLocation = location
        let body = Self.body(from: location)
        Task { await send(body) }
    }

    static func body(from loc: CLLocation) -> TrackBody {
        var battery: Int?
        var charging: Bool?
        #if canImport(UIKit)
        let level = UIDevice.current.batteryLevel  // -1 when unknown
        if level >= 0 { battery = Int((level * 100).rounded()) }
        switch UIDevice.current.batteryState {
        case .charging, .full: charging = true
        case .unplugged:       charging = false
        default:               charging = nil
        }
        #endif
        return TrackBody(
            lat: loc.coordinate.latitude,
            lng: loc.coordinate.longitude,
            accuracy: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil,
            altitude: loc.verticalAccuracy >= 0 ? loc.altitude : nil,
            speed: loc.speed >= 0 ? loc.speed : nil,
            heading: loc.course >= 0 ? loc.course : nil,
            batteryLevel: battery,
            batteryCharging: charging,
            clientTs: Int64(loc.timestamp.timeIntervalSince1970 * 1000)
        )
    }
}

extension TraxLocationProducer: CLLocationManagerDelegate {
    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor [weak self] in self?.publish(loc) }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.beginUpdates()
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            // kCLErrorLocationUnknown is transient — CL retries; ignore.
            if (error as? CLError)?.code == .locationUnknown { return }
            self?.lastError = error.localizedDescription
        }
    }
}
