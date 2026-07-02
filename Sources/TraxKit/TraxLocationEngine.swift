import Foundation
import CoreLocation
import CoreMotion
import UIKit

/// The kit's default `TraxLocationHost` — the device location engine (single
/// `CLLocationManager` + rolling-20 geofence + motion/battery). Ships in TraxKit so
/// a host doesn't have to reimplement CoreLocation; the `TraxLocationHost` protocol
/// stays public so any host CAN bring its own, but this is the one the app uses.
///
/// This is the single implementation that replaced two near-identical copies
/// (Clingy's `ClingyTraxLocationHost` + TraxLab's `TraxLabLocationEngine`). The only
/// host-specific behavior — wrapping a system permission prompt so its brief
/// `.inactive` blip isn't read as a real backgrounding (Clingy's privacy-lock /
/// socket-drop protection) — is injected as `TraxEnginePolicy` closures. TraxLab
/// passes the defaults (no-ops); Clingy passes its `AppCoordinator` dialog guard.
///
/// This is the ONE file in the kit that touches device APIs (CoreLocation /
/// CoreMotion / UIKit). `TraxLocationHost.swift` (the protocol) stays pure-data and
/// host-agnostic, so tests keep faking the seam.
@MainActor
public final class TraxLocationEngine: NSObject, TraxLocationHost, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let motionMgr = CMMotionActivityManager()
    private let policy: TraxEnginePolicy
    private var motion: String?
    private var motionRunning = false
    /// True while THIS engine is holding the host's system-dialog guard open for a
    /// prompt it triggered — so the balancing `endSystemDialog` only ever fires for
    /// our own prompt, never an unrelated dialog's (the guard is a shared flag).
    private var locationDidBeginDialog = false
    private var motionDidBeginDialog = false
    private var demand: TraxTrackingDemand = .off
    private var regions: [UUID: TraxRegion] = [:]

    private var latestFix: TraxFix?
    private var fixContinuation: AsyncStream<TraxFix>.Continuation?
    private var transitionContinuation: AsyncStream<TraxTransition>.Continuation?

    /// - Parameter policy: host hooks for wrapping permission prompts. Defaults to
    ///   no-ops — correct for any host without a privacy-lock (e.g. TraxLab).
    public init(policy: TraxEnginePolicy = TraxEnginePolicy()) {
        self.policy = policy
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - Session lifecycle

    /// Engage device hardware for a signed-in session. Battery monitoring comes up
    /// here (not in `init`) so nothing runs before login; motion engages lazily via
    /// `applyDemand` once location is authorized + tracking.
    public func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// Disengage everything on logout — a harder stop than the kit's `.off` (which is
    /// "idle / significant-only", a still-signed-in state). Stops all CL monitoring +
    /// motion + battery and finishes the fix/transition streams.
    public func stop() {
        demand = .off
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.monitoredRegions.forEach { manager.stopMonitoring(for: $0) }
        stopMotion()
        UIDevice.current.isBatteryMonitoringEnabled = false
        fixContinuation?.finish();        fixContinuation = nil
        transitionContinuation?.finish(); transitionContinuation = nil
        regions = [:]
        latestFix = nil
        endDialogIfHeld()   // logout mid-prompt: don't leave the guard wedged
    }

    /// Release any system-dialog guard this engine is currently holding.
    private func endDialogIfHeld() {
        guard locationDidBeginDialog || motionDidBeginDialog else { return }
        locationDidBeginDialog = false
        motionDidBeginDialog = false
        policy.endSystemDialog()
    }

    // MARK: - TraxLocationHost

    public var currentFix: TraxFix? { latestFix }

    public func fixStream() -> AsyncStream<TraxFix> {
        AsyncStream { continuation in self.fixContinuation = continuation }
    }

    public func transitionStream() -> AsyncStream<TraxTransition> {
        AsyncStream { continuation in self.transitionContinuation = continuation }
    }

    public var authorization: TraxLocationAuth {
        switch manager.authorizationStatus {
        case .authorizedAlways:        .always
        case .authorizedWhenInUse:     .whenInUse
        case .denied, .restricted:     .denied
        default:                       .notDetermined
        }
    }

    /// The active decision point — the host's system-dialog guard wraps the prompt.
    public func requestLocationAccess() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // A prompt WILL appear and resolve via didChangeAuthorization — hold the
            // guard so its brief .inactive blip isn't read as a backgrounding.
            policy.beginSystemDialog()
            locationDidBeginDialog = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // The when-in-use -> always upgrade is intentionally NOT guarded: iOS
            // frequently defers/suppresses it with no status change, so
            // didChangeAuthorization never fires and the guard would wedge true
            // (background socket never released). If iOS does show it, the brief
            // blip self-heals on reconnect — far cheaper than a stuck guard.
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    public func setMonitoredRegions(_ regions: [TraxRegion]) {
        self.regions = Dictionary(uniqueKeysWithValues: regions.map { ($0.placeID, $0) })
        reconcileRegions()
    }

    public func setDesiredTracking(_ demand: TraxTrackingDemand) {
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
        startMotionIfNeeded()   // motion follows location: only once authorized + tracking
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

    private func startMotionIfNeeded() {
        guard CMMotionActivityManager.isActivityAvailable(), !motionRunning else { return }
        motionRunning = true
        // Mirror the location prompt: guard the first query when it will actually
        // prompt. CoreMotion has no auth-change delegate, so balance the guard on the
        // first callback after the user responds (fires for grant OR deny).
        if CMMotionActivityManager.authorizationStatus() == .notDetermined {
            policy.beginSystemDialog()
            motionDidBeginDialog = true
        }
        motionMgr.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self else { return }
            if self.motionDidBeginDialog {
                self.motionDidBeginDialog = false
                self.policy.endSystemDialog()
            }
            guard let activity else { return }
            self.motion = Self.classify(activity)
        }
    }

    private func stopMotion() {
        guard motionRunning else { return }
        motionMgr.stopActivityUpdates()
        motionRunning = false
        motion = nil
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

    nonisolated public func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            let fix = self.makeFix(loc)
            self.latestFix = fix
            self.fixContinuation?.yield(fix)
        }
    }

    nonisolated public func locationManager(_ m: CLLocationManager, didEnterRegion region: CLRegion) {
        emit(region.identifier, .enter)
    }
    nonisolated public func locationManager(_ m: CLLocationManager, didExitRegion region: CLRegion) {
        emit(region.identifier, .leave)
    }
    nonisolated public func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            if self.locationDidBeginDialog {   // only end a guard WE opened (CL also
                self.locationDidBeginDialog = false   // fires this on delegate-set
                self.policy.endSystemDialog()         // and Settings toggles)
            }
            self.applyDemand()
            self.reconcileRegions()
        }
    }

    nonisolated private func emit(_ regionID: String, _ event: TraxEvent) {
        guard let id = UUID(uuidString: regionID) else { return }
        Task { @MainActor in
            self.transitionContinuation?.yield(TraxTransition(placeID: id, event: event, timestamp: Date()))
        }
    }
}

/// Host hooks the kit's `TraxLocationEngine` calls around a system permission prompt.
/// A host with a privacy-lock (Clingy) passes its dialog guard so the prompt's brief
/// `.inactive` blip isn't read as a backgrounding; hosts without one (TraxLab) use
/// the no-op defaults. Both closures run on the main actor (where prompts happen).
public struct TraxEnginePolicy {
    public var beginSystemDialog: @MainActor () -> Void
    public var endSystemDialog: @MainActor () -> Void

    public init(beginSystemDialog: @escaping @MainActor () -> Void = {},
                endSystemDialog: @escaping @MainActor () -> Void = {}) {
        self.beginSystemDialog = beginSystemDialog
        self.endSystemDialog = endSystemDialog
    }
}
