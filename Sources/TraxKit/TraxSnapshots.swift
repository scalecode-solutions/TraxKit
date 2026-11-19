import Foundation
import CoreLocation

// Value snapshots of what the store holds, published by `TraxSync` so views
// (the kit's and a host's) never read SwiftData models inside a body. A fetch
// made inside a view body registers no observation, so a view that fetched
// never re-rendered when the poll changed the data; a published value does.

/// One sharer's current presented location (the newest unexpired share they
/// have pointed at me), as a value.
struct IncomingShareSnapshot: Equatable, Sendable {
    let shareID: UUID
    let ownerID: UUID
    let precision: String
    let lat: Double?
    let lng: Double?
    let placeName: String?
    let atPlace: Bool
    let speed: Double?
    let motion: String?
    let batteryLevel: Int?
    let batteryCharging: Bool?
    let locRecordedAt: Int64?
    let expiresAt: Int64?

    init(_ e: ShareEntity) {
        shareID = e.id; ownerID = e.ownerId; precision = e.precision
        lat = e.lat; lng = e.lng; placeName = e.placeName; atPlace = e.atPlace
        speed = e.speed; motion = e.motion
        batteryLevel = e.batteryLevel; batteryCharging = e.batteryCharging
        locRecordedAt = e.locRecordedAt; expiresAt = e.expiresAt
    }

    /// The bridge's public shape. Liveness is computed at read time (it's a
    /// function of the clock, not of the data).
    func summary(now: Date = Date()) -> TraxLocationSummary {
        let st = TraxMemberStatus.make(speedMps: speed, motion: motion, batteryLevel: batteryLevel,
                                       batteryCharging: batteryCharging ?? false,
                                       recordedAtMs: locRecordedAt, now: now)
        let coord = (lat != nil && lng != nil) ? CLLocationCoordinate2D(latitude: lat!, longitude: lng!) : nil
        return TraxLocationSummary(
            coordinate: coord, placeName: placeName, atPlace: atPlace, precision: precision,
            battery: batteryLevel, batteryCharging: batteryCharging ?? false,
            lastUpdatedMs: locRecordedAt, isLive: st.isLive)
    }
}

/// A place visible to me (mine, or shared with me), as a value.
struct PlaceSnapshot: Equatable, Sendable {
    let id: UUID
    let ownerID: UUID
    let name: String
    let emoji: String?
    let lat: Double
    let lng: Double
    let radiusM: Int
    let sharedWith: [UUID]

    init(_ e: PlaceEntity) {
        id = e.id; ownerID = e.ownerId; name = e.name; emoji = e.emoji
        lat = e.lat; lng = e.lng; radiusM = e.radiusM; sharedWith = e.sharedWith
    }
}
