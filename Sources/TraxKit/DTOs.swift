import Foundation

// Wire DTOs — the exact mvTrax contract. Value types, so `Sendable` is free;
// `public` types in a library are not implicitly Sendable, so we spell it out.
// All timestamps are epoch-millis (Int64).

/// A single location fix (the telemetry payload). Nested under a share's
/// `location` on the feed; flattened onto a `PointDTO` for the trail.
public struct LocationDTO: Codable, Sendable, Hashable {
    public let lat: Double
    public let lng: Double
    public let accuracy: Double?
    public let altitude: Double?
    public let speed: Double?
    public let heading: Double?
    public let motion: String?
    public let network: String?
    public let batteryLevel: Int?
    public let batteryCharging: Bool?
    public let clientTs: Int64?
    public let recordedAt: Int64

    public init(lat: Double, lng: Double, accuracy: Double? = nil, altitude: Double? = nil,
                speed: Double? = nil, heading: Double? = nil, motion: String? = nil,
                network: String? = nil, batteryLevel: Int? = nil, batteryCharging: Bool? = nil,
                clientTs: Int64? = nil, recordedAt: Int64) {
        self.lat = lat; self.lng = lng; self.accuracy = accuracy; self.altitude = altitude
        self.speed = speed; self.heading = heading; self.motion = motion; self.network = network
        self.batteryLevel = batteryLevel; self.batteryCharging = batteryCharging
        self.clientTs = clientTs; self.recordedAt = recordedAt
    }
}

/// A directed share. On the feed, `location` is the owner's current head (nil
/// until they've produced a fix). Owner = the person sharing; viewer = recipient.
public struct ShareDTO: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let ownerId: UUID
    public let viewerId: UUID
    public let mode: String       // "live" | "breadcrumb"
    public let retention: String  // "none" | "indefinite"
    public let startedAt: Int64
    public let expiresAt: Int64?
    public let location: LocationDTO?

    public init(id: UUID, ownerId: UUID, viewerId: UUID, mode: String, retention: String,
                startedAt: Int64, expiresAt: Int64? = nil, location: LocationDTO? = nil) {
        self.id = id; self.ownerId = ownerId; self.viewerId = viewerId; self.mode = mode
        self.retention = retention; self.startedAt = startedAt; self.expiresAt = expiresAt
        self.location = location
    }
}

/// One viewer pull-feed page: who is sharing with me + where they are now, plus
/// any place enter/leave events since the cursor.
public struct FeedDTO: Codable, Sendable {
    public let shares: [ShareDTO]
    public let transitions: [TransitionDTO]?
    public let syncTs: Int64
    public let hasMore: Bool
    public let stoppedIds: [UUID]?

    public init(shares: [ShareDTO], transitions: [TransitionDTO]? = nil, syncTs: Int64,
                hasMore: Bool, stoppedIds: [UUID]?) {
        self.shares = shares; self.transitions = transitions; self.syncTs = syncTs
        self.hasMore = hasMore; self.stoppedIds = stoppedIds
    }
}

/// A saved place (home/work/custom) with a geofence radius.
public struct PlaceDTO: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let ownerId: UUID
    public let name: String
    public let type: String      // home | work | custom
    public let lat: Double
    public let lng: Double
    public let radiusM: Int
    public let emoji: String?
    public let address: String?
    public let createdAt: Int64
    public let updatedAt: Int64
}

/// The caller's saved places.
public struct PlacesDTO: Codable, Sendable {
    public let places: [PlaceDTO]
    public init(places: [PlaceDTO]) { self.places = places }
}

/// A place enter/leave event (someone you can see arrived at / left a place).
public struct TransitionDTO: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let ownerId: UUID
    public let placeId: UUID
    public let placeName: String
    public let placeEmoji: String?
    public let event: String     // enter | leave
    public let createdAt: Int64
}

// --- request bodies (places + transition) ---

/// Create/edit a place.
public struct PlaceBody: Codable, Sendable {
    public var name: String
    public var type: String
    public var lat: Double
    public var lng: Double
    public var radiusM: Int
    public var emoji: String?
    public var address: String?
    public init(name: String, type: String = "custom", lat: Double, lng: Double,
                radiusM: Int = 150, emoji: String? = nil, address: String? = nil) {
        self.name = name; self.type = type; self.lat = lat; self.lng = lng
        self.radiusM = radiusM; self.emoji = emoji; self.address = address
    }
}

/// A device-published place enter/leave.
public struct TransitionBody: Codable, Sendable {
    public var placeId: UUID
    public var event: String     // enter | leave
    public var lat: Double?
    public var lng: Double?
    public init(placeId: UUID, event: String, lat: Double? = nil, lng: Double? = nil) {
        self.placeId = placeId; self.event = event; self.lat = lat; self.lng = lng
    }
}

/// My outgoing + incoming active shares.
public struct SharesDTO: Codable, Sendable {
    public let outgoing: [ShareDTO]
    public let incoming: [ShareDTO]
    public init(outgoing: [ShareDTO], incoming: [ShareDTO]) {
        self.outgoing = outgoing; self.incoming = incoming
    }
}

/// A breadcrumb point. The server flattens the location fields onto the row, so
/// this is a flat struct (id + the LocationDTO fields).
public struct PointDTO: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let lat: Double
    public let lng: Double
    public let accuracy: Double?
    public let altitude: Double?
    public let speed: Double?
    public let heading: Double?
    public let motion: String?
    public let network: String?
    public let batteryLevel: Int?
    public let batteryCharging: Bool?
    public let clientTs: Int64?
    public let recordedAt: Int64
}

/// An owner's breadcrumb trail page.
public struct PointsDTO: Codable, Sendable {
    public let ownerId: UUID
    public let points: [PointDTO]
    public init(ownerId: UUID, points: [PointDTO]) { self.ownerId = ownerId; self.points = points }
}

/// Ack for a track ingest — `shares` is the fan-out breadth (active shares).
public struct TrackAckDTO: Codable, Sendable {
    public let ok: Bool
    public let shares: Int
    public let ts: Int64
    public init(ok: Bool, shares: Int, ts: Int64) { self.ok = ok; self.shares = shares; self.ts = ts }
}

/// Simple `{count}` response (stop-all, clear-history, dev seed).
public struct CountDTO: Codable, Sendable {
    public let count: Int64
    public init(count: Int64) { self.count = count }
}

/// A friend from the social-graph people directory: id + identity. Avatar is a
/// base64 thumbnail, omitted when the person has none.
public struct TraxContact: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let avatar: String?
    public init(id: UUID, name: String, avatar: String? = nil) {
        self.id = id; self.name = name; self.avatar = avatar
    }
}

/// The caller's friends — the share candidates.
public struct ContactsDTO: Codable, Sendable {
    public let contacts: [TraxContact]
    public init(contacts: [TraxContact]) { self.contacts = contacts }
}

// --- request bodies ---

/// A location fix to ingest (POST /v0/track). recordedAt defaults server-side to now.
public struct TrackBody: Codable, Sendable {
    public var lat: Double
    public var lng: Double
    public var accuracy: Double?
    public var altitude: Double?
    public var speed: Double?
    public var heading: Double?
    public var motion: String?
    public var network: String?
    public var batteryLevel: Int?
    public var batteryCharging: Bool?
    public var clientTs: Int64?
    public var recordedAt: Int64?

    public init(lat: Double, lng: Double, accuracy: Double? = nil, altitude: Double? = nil,
                speed: Double? = nil, heading: Double? = nil, motion: String? = nil,
                network: String? = nil, batteryLevel: Int? = nil, batteryCharging: Bool? = nil,
                clientTs: Int64? = nil, recordedAt: Int64? = nil) {
        self.lat = lat; self.lng = lng; self.accuracy = accuracy; self.altitude = altitude
        self.speed = speed; self.heading = heading; self.motion = motion; self.network = network
        self.batteryLevel = batteryLevel; self.batteryCharging = batteryCharging
        self.clientTs = clientTs; self.recordedAt = recordedAt
    }
}

/// Start a directed share with a friend (POST /v0/shares).
public struct StartShareBody: Codable, Sendable {
    public var viewer: UUID
    public var mode: String?
    public var retention: String?
    public var expiresIn: Int?   // seconds from now; nil = until stopped
    public init(viewer: UUID, mode: String? = nil, retention: String? = nil, expiresIn: Int? = nil) {
        self.viewer = viewer; self.mode = mode; self.retention = retention; self.expiresIn = expiresIn
    }
}
