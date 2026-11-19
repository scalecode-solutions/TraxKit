import Foundation
import CoreLocation
import CoreMotion
import UIKit
import os

/// The kit's default `TraxLocationHost` — the device location engine (single
/// `CLLocationManager` + rolling-20 geofence + motion/battery). Ships in TraxKit so
/// a host doesn't have to reimplement CoreLocation; the `TraxLocationHost` protocol
/// stays public so any host CAN bring its own, but this is the one the app uses.
///
/// This is the single implementation that replaced two near-identical copies
/// (one in a host app, one in TraxLab). The only
/// host-specific behavior — wrapping a system permission prompt so its brief
/// `.inactive` blip isn't read as a real backgrounding (a host's privacy lock /
/// socket-drop protection) — is injected as `TraxEnginePolicy` closures. TraxLab
/// passes the defaults (no-ops); a host with a privacy lock passes its dialog guard.
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
    /// Crossings detected while nobody is listening (a cold launch by a geofence
    /// wakes the app before the kit subscribes): handed to the next subscriber
    /// instead of dropped. Newest kept, capped.
    private var pendingTransitions: [TraxTransition] = []
    static let pendingTransitionCap = 50
    /// Where the rolling-20 was last ranked from; re-ranked after moving `rerankAfterMeters`.
    private var rankedFrom: CLLocation?
    static let rerankAfterMeters: CLLocationDistance = 1_000
    /// Exact (`.continuous`): no distance filter. A filter would stop a still
    /// phone's fixes entirely, and with no fix nothing is posted, so its viewers
    /// would see "Not updating" (MVTRAX-22). UploadPolicy decides what's posted
    /// (moved, motion changed, or the 90 s heartbeat); the power knob is
    /// accuracy, which drops to ~100 m while still, so the cost is wakeups,
    /// not GPS.
    nonisolated static let continuousDistanceFilter: CLLocationDistance = kCLDistanceFilterNone
    private let log = Logger(subsystem: "TraxKit", category: "location")

    /// - Parameter policy: host hooks for wrapping permission prompts. Defaults to
    ///   no-ops — correct for any host without a privacy-lock (e.g. TraxLab).
    public init(policy: TraxEnginePolicy = TraxEnginePolicy()) {
        self.policy = policy
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = Self.continuousDistanceFilter
        // Never let iOS pause updates when the phone is still: an exact sharer's
        // heartbeat (MVTRAX-22) depends on fixes continuing while it sits still.
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
        pendingTransitions = []   // a signed-out session's crossings never reach the next one
        regions = [:]
        rankedFrom = nil
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
        let (stream, continuation) = AsyncStream.makeStream(of: TraxFix.self, bufferingPolicy: .bufferingNewest(1))
        fixContinuation = continuation
        return stream
    }

    /// Crossings from now on, starting with any detected while nobody listened.
    /// When this subscriber goes away, crossings are buffered again.
    public func transitionStream() -> AsyncStream<TraxTransition> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: TraxTransition.self, bufferingPolicy: .bufferingNewest(Self.pendingTransitionCap))
        for t in pendingTransitions { continuation.yield(t) }
        pendingTransitions = []
        let token = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                // Only forget it if it's still the current subscriber.
                guard let self, self.transitionToken == token else { return }
                self.transitionContinuation = nil
            }
        }
        transitionToken = token
        transitionContinuation = continuation
        return stream
    }
    private var transitionToken = UUID()

    func deliver(_ t: TraxTransition) {
        if let c = transitionContinuation {
            if case .terminated = c.yield(t) {} else { return }
        }
        // No listener (or one that just went away): keep it for the next.
        transitionContinuation = nil
        pendingTransitions.append(t)
        if pendingTransitions.count > Self.pendingTransitionCap {
            pendingTransitions.removeFirst(pendingTransitions.count - Self.pendingTransitionCap)
        }
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
        case .off:
            // Off is off: no GPS, no motion. The one exception is keeping a
            // rolling-20 geofence budget ranked when there are more places than
            // regions (Always only; significant-change is the cheapest signal).
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            if s == .authorizedAlways && regions.count > 20 {
                manager.startMonitoringSignificantLocationChanges()
            } else {
                manager.stopMonitoringSignificantLocationChanges()
            }
            stopMotion()
        case .significant:
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            manager.startMonitoringSignificantLocationChanges()
            startMotionIfNeeded()
        case .approximate, .coarse, .continuous:
            manager.stopMonitoringSignificantLocationChanges()
            applyAccuracy()
            manager.startUpdatingLocation()
            startMotionIfNeeded()   // motion follows location: only once authorized + tracking
        }
    }

    /// What CoreLocation is asked for in each updating tier.
    nonisolated struct UpdateProfile: Equatable, Sendable {
        let accuracy: CLLocationAccuracy
        let distanceFilter: CLLocationDistance
        let background: Bool
    }

    /// Pure: the settings for a tier. Only exact (`.continuous`) keeps updating
    /// in the background, and only when the host declares the `location`
    /// background mode (setting allowsBackgroundLocationUpdates without it
    /// crashes). Exact runs at full GPS while moving and coarse while the
    /// motion says the device is still.
    nonisolated static func profile(for demand: TraxTrackingDemand, stationary: Bool,
                        hasBackgroundMode: Bool) -> UpdateProfile? {
        switch demand {
        case .off, .significant:
            return nil
        case .approximate:
            return UpdateProfile(accuracy: kCLLocationAccuracyKilometer, distanceFilter: 500, background: false)
        case .coarse:
            return UpdateProfile(accuracy: kCLLocationAccuracyHundredMeters, distanceFilter: 50, background: false)
        case .continuous:
            return UpdateProfile(accuracy: stationary ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyBest,
                                 distanceFilter: continuousDistanceFilter, background: hasBackgroundMode)
        }
    }

    nonisolated static let hostHasBackgroundMode: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") ?? false

    /// Apply the current tier's profile (re-run when the motion changes, so a
    /// phone on a desk doesn't hold the radio at full power).
    private func applyAccuracy() {
        guard let p = Self.profile(for: demand, stationary: motion == "stationary",
                                   hasBackgroundMode: Self.hostHasBackgroundMode) else { return }
        if manager.desiredAccuracy != p.accuracy { manager.desiredAccuracy = p.accuracy }
        if manager.distanceFilter != p.distanceFilter { manager.distanceFilter = p.distanceFilter }
        if manager.allowsBackgroundLocationUpdates != p.background { manager.allowsBackgroundLocationUpdates = p.background }
    }

    /// Rolling-20 nearest to the current fix (the single-owner region budget).
    /// Region monitoring needs Always: under When-In-Use iOS doesn't deliver
    /// crossings in the background, so nothing is armed rather than half-armed.
    private func reconcileRegions() {
        guard manager.authorizationStatus == .authorizedAlways else {
            manager.monitoredRegions.forEach { manager.stopMonitoring(for: $0) }
            return
        }
        if let fix = latestFix { rankedFrom = CLLocation(latitude: fix.lat, longitude: fix.lng) }
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
            self.applyAccuracy()
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
            self.rerankIfMoved(loc)
        }
    }

    /// More places than regions: re-rank the rolling-20 once the device has
    /// moved far enough that the nearest twenty may have changed.
    private func rerankIfMoved(_ loc: CLLocation) {
        guard regions.count > 20 else { return }
        if let from = rankedFrom, loc.distance(from: from) < Self.rerankAfterMeters { return }
        reconcileRegions()
    }

    nonisolated public func locationManager(_ m: CLLocationManager, monitoringDidFailFor region: CLRegion?,
                                            withError error: any Error) {
        let id = region?.identifier ?? "?"
        Task { @MainActor in
            self.log.error("region monitoring failed for \(id, privacy: .private): \(error.localizedDescription, privacy: .public)")
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
        let at = Date()
        Task { @MainActor in
            self.deliver(TraxTransition(placeID: id, event: event, timestamp: at))
        }
    }
}

/// Host hooks the kit's `TraxLocationEngine` calls around a system permission prompt.
/// A host with a privacy lock passes its dialog guard so the prompt's brief
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
