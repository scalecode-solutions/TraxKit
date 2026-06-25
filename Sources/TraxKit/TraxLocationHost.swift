import Foundation

// The seam between TraxKit (the data + transport rail) and the host's location
// ENGINE (Clingy in prod, TraxLab in dev). TraxKit owns zero CoreLocation; the host
// owns the single CLLocationManager + the rolling-20 geofence and feeds the rail
// through this protocol. See docs/REBUILD-ARCHITECTURE.md.
//
// Deliberately pure-data (lat/lng Doubles, no CoreLocation import): the host maps
// CLLocation → TraxFix, the kit maps TraxFix → the wire. Nothing here touches a
// device API, so it stays Sendable and host-agnostic.

/// One enriched device fix — exactly the inputs the kit needs to post a track point.
/// The host assembles it from CoreLocation + CoreMotion + UIDevice.
public struct TraxFix: Sendable, Hashable {
    public let lat: Double
    public let lng: Double
    public let horizontalAccuracy: Double?
    public let altitude: Double?
    public let speed: Double?
    public let course: Double?
    public let motion: String?          // stationary|walking|running|cycling|automotive
    public let batteryLevel: Int?       // 0...100
    public let batteryCharging: Bool?
    public let timestamp: Date

    public init(lat: Double, lng: Double, horizontalAccuracy: Double? = nil,
                altitude: Double? = nil, speed: Double? = nil, course: Double? = nil,
                motion: String? = nil, batteryLevel: Int? = nil, batteryCharging: Bool? = nil,
                timestamp: Date) {
        self.lat = lat; self.lng = lng
        self.horizontalAccuracy = horizontalAccuracy; self.altitude = altitude
        self.speed = speed; self.course = course
        self.motion = motion
        self.batteryLevel = batteryLevel; self.batteryCharging = batteryCharging
        self.timestamp = timestamp
    }
}

/// A place the kit wants the host's geofence to monitor. The host merges these into
/// its single rolling-20 region budget; the kit's places are the source of truth.
public struct TraxRegion: Sendable, Hashable, Identifiable {
    public let placeID: UUID
    public let lat: Double
    public let lng: Double
    public let radiusMeters: Double
    public var id: UUID { placeID }

    public init(placeID: UUID, lat: Double, lng: Double, radiusMeters: Double) {
        self.placeID = placeID; self.lat = lat; self.lng = lng; self.radiusMeters = radiusMeters
    }
}

public enum TraxEvent: String, Sendable, Hashable { case enter, leave }

/// A boundary crossing the host's geofence detected, handed back to the kit to
/// record + post + fan out. The host detects; the kit owns it as data.
public struct TraxTransition: Sendable, Hashable {
    public let placeID: UUID
    public let event: TraxEvent
    public let timestamp: Date

    public init(placeID: UUID, event: TraxEvent, timestamp: Date) {
        self.placeID = placeID; self.event = event; self.timestamp = timestamp
    }
}

/// How aggressively the kit needs the host to track — driven by share state, NOT by
/// leaking who's watching. The host decides how to satisfy it (accuracy/tier/battery).
public enum TraxTrackingDemand: Sendable, Hashable {
    case off            // not sharing — the host can idle / significant-change only
    case significant    // sharing but nobody actively watching — cheap tier
    case continuous     // active live watcher — tight tier
}

/// Location authorization, as the kit reads it. The host owns the prompt.
public enum TraxLocationAuth: Sendable, Hashable {
    case notDetermined, denied, whenInUse, always
}

/// The contract the host implements. The kit holds one instance and:
///   • consumes fixes (poster), the snapshot (map dot / "use current location"),
///     auth state, and transitions;
///   • provides the regions to monitor and its tracking demand.
@MainActor
public protocol TraxLocationHost: AnyObject {
    /// Latest fix, for the map's self-dot and the place editor's "use current location".
    var currentFix: TraxFix? { get }
    /// Live fixes for the poster (single consumer: the sync's track loop).
    func fixStream() -> AsyncStream<TraxFix>

    /// Auth state the kit reads; `requestLocationAccess` delegates the prompt to the host.
    var authorization: TraxLocationAuth { get }
    func requestLocationAccess()

    /// The kit hands its place-regions in; the host merges them into its rolling-20.
    func setMonitoredRegions(_ regions: [TraxRegion])
    /// The kit's tracking demand (off/significant/continuous), driven by share state.
    func setDesiredTracking(_ demand: TraxTrackingDemand)
    /// Boundary crossings the host's geofence detected, for the kit to record + post.
    func transitionStream() -> AsyncStream<TraxTransition>
}
