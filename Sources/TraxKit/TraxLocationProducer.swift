import Foundation
import CoreLocation
import CoreMotion
#if canImport(UIKit)
import UIKit
#endif

/// Acquires device location and POSTs fixes to mvTrax (`/v0/track`), with
/// **adaptive cadence** — the headline. Cadence is driven by three live signals,
/// not a fixed timer or a manual mode picker (OwnTracks' learning curve):
///
///   • **motion** (CMMotionActivity): driving/running → tight; walking → medium;
///     stationary → slow. Also fills the real `motion` telemetry field.
///   • **battery**: stretch intervals under 30%/15%; significant-change only <5%.
///   • **watchers**: if nobody is actively sharing-to (no one's watching you) and
///     timeline is off, drop to significant-change only — the big battery win that
///     OwnTracks/Life360 can't do cheaply, but our share graph makes obvious.
///
/// CoreLocation essentials (continuous `startUpdatingLocation` +
/// `allowsBackgroundLocationUpdates` + `pausesAutomatically = false`) are lifted
/// from OwnTracks' Move mode; the adaptive layer is ours.
@MainActor
public final class TraxLocationProducer: NSObject {
    /// Heartbeat: republish at least this often even when stationary (continuous mode).
    public var heartbeat: TimeInterval = 60

    /// Set by the host when the set of people actively watching changes. Drives
    /// the watcher-aware tier. Re-evaluates cadence on change.
    public var hasWatchers: Bool = false {
        didSet { if hasWatchers != oldValue { reevaluate() } }
    }
    /// Personal-history producer (timeline). When on, we keep producing even with
    /// no watchers. Off for now (timeline is a later piece).
    public var timelineEnabled: Bool = false {
        didSet { if timelineEnabled != oldValue { reevaluate() } }
    }

    public private(set) var isRunning = false
    public private(set) var lastError: String?

    private let manager = CLLocationManager()
    private let motionMgr = CMMotionActivityManager()
    private let send: @Sendable (TrackBody) async -> Void

    private enum Mode { case off, significant, continuous }
    private var mode: Mode = .off
    private var motion: String?            // stationary|walking|running|cycling|automotive
    private var lastSentAt: Date?
    private var lastSentLocation: CLLocation?
    private var heartbeatTimer: Timer?

    public init(send: @escaping @Sendable (TrackBody) async -> Void) {
        self.send = send
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        // Permissions are requested up front by the onboarding (TraxPermissions),
        // never here — the producer only consumes what's granted, so it can't
        // ambush-prompt. Denied location simply yields no production (watch-only).
        startMotion()
        reevaluate()
        startHeartbeat()
    }

    public func stop() {
        isRunning = false
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        motionMgr.stopActivityUpdates()
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        mode = .off
    }

    // MARK: - Adaptive policy

    /// Desired publish interval in continuous mode (seconds), or nil meaning
    /// "don't run continuous — significant-change only is enough right now".
    private func desiredInterval() -> TimeInterval? {
        let battery = batteryPercent()
        if let b = battery, b <= 5 { return nil }                 // critical: cheapest
        if !hasWatchers && !timelineEnabled { return nil }        // nobody watching: cheapest

        // Tuned for a tiny close network (≤6 users): tight when moving, since the
        // upload volume is trivial. 10s is the sweet spot; ~5s while driving.
        var base: TimeInterval
        switch motion {
        case "automotive": base = 5    // traveling — keep the dot live
        case "running":    base = 7
        case "cycling":    base = 10
        case "walking":    base = 12
        case "stationary": base = 60   // parked — refresh occasionally
        default:           base = 10   // unknown motion — the sweet spot
        }
        if let b = battery {
            if b <= 15 { base *= 3 }
            else if b <= 30 { base *= 1.5 }
        }
        return base
    }

    /// Pick the CL mode from the policy and switch hardware accordingly.
    private func reevaluate() {
        guard isRunning else { return }
        let s = manager.authorizationStatus
        guard s == .authorizedAlways || s == .authorizedWhenInUse else { return }

        let want: Mode = desiredInterval() == nil ? .significant : .continuous
        if want == mode { return }

        switch want {
        case .continuous:
            manager.stopMonitoringSignificantLocationChanges()
            manager.allowsBackgroundLocationUpdates = (s == .authorizedAlways) && hostAllowsBackground
            if hostAllowsBackground { manager.showsBackgroundLocationIndicator = true }
            manager.startUpdatingLocation()
        case .significant:
            manager.stopUpdatingLocation()
            // Significant-change still works backgrounded and wakes the app; it's
            // the cheap "nobody's watching / critical battery" tier.
            manager.startMonitoringSignificantLocationChanges()
        case .off:
            break
        }
        mode = want
    }

    private var hostAllowsBackground: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?
            .contains("location") ?? false
    }

    // MARK: - Motion

    private func startMotion() {
        // Only consume motion if it's already authorized — never trigger the
        // prompt here (the onboarding owns that). Unauthorized → no classification;
        // cadence just falls back to its motion-unknown default.
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized else { return }
        motionMgr.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            let m = Self.classify(activity)
            Task { @MainActor in self?.onMotion(m) }
        }
    }

    private func onMotion(_ m: String?) {
        let changed = m != motion
        motion = m
        if changed { reevaluate() }   // motion class changed → cadence may change
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

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let t = Timer(timeInterval: heartbeat, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeatTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
    }

    private func heartbeatTick() {
        // Only force a refresh in continuous mode; significant mode is OS-paced.
        guard isRunning, mode == .continuous, let loc = manager.location else { return }
        publish(loc, force: true)
    }

    // MARK: - Publish

    private func publish(_ location: CLLocation, force: Bool = false) {
        if !force, mode == .continuous, let interval = desiredInterval(), let last = lastSentAt {
            if Date().timeIntervalSince(last) < interval { return }
        }
        lastSentAt = Date()
        lastSentLocation = location
        let body = makeBody(location)
        Task { await send(body) }
    }

    private func makeBody(_ loc: CLLocation) -> TrackBody {
        var battery: Int?
        var charging: Bool?
        #if canImport(UIKit)
        let level = UIDevice.current.batteryLevel
        if level >= 0 { battery = Int((level * 100).rounded()) }
        switch UIDevice.current.batteryState {
        case .charging, .full: charging = true
        case .unplugged:       charging = false
        default:               charging = nil
        }
        #endif
        return TrackBody(
            lat: loc.coordinate.latitude, lng: loc.coordinate.longitude,
            accuracy: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil,
            altitude: loc.verticalAccuracy >= 0 ? loc.altitude : nil,
            speed: loc.speed >= 0 ? loc.speed : nil,
            heading: loc.course >= 0 ? loc.course : nil,
            motion: motion,
            batteryLevel: battery, batteryCharging: charging,
            clientTs: Int64(loc.timestamp.timeIntervalSince1970 * 1000))
    }

    #if canImport(UIKit)
    private func batteryPercent() -> Int? {
        let l = UIDevice.current.batteryLevel
        return l >= 0 ? Int((l * 100).rounded()) : nil
    }
    #else
    private func batteryPercent() -> Int? { nil }
    #endif
}

extension TraxLocationProducer: CLLocationManagerDelegate {
    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor [weak self] in self?.publish(loc) }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.mode = .off          // force a fresh mode switch under the new auth
            self.reevaluate()
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            if (error as? CLError)?.code == .locationUnknown { return }
            self?.lastError = error.localizedDescription
        }
    }
}
