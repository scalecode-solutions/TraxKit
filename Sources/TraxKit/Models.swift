import Foundation
import SwiftData

// SwiftData persistence models — TraxKit owns its own store (its own SQLite file),
// fully isolated from the host's GRDB (chat) and any other SwiftData container.
// @Model classes are reference types and are NOT Sendable; they live only on the
// main actor (see TraxStore / @MainActor), so they never cross an isolation
// boundary.

/// A share pointed at me (I'm the viewer): who is sharing their location with me,
/// plus their current position head (nil fields until they've produced a fix).
/// This is exactly what the viewer feed delivers.
@Model
public final class ShareEntity {
    @Attribute(.unique) public var id: UUID
    public var ownerId: UUID
    public var mode: String
    public var retention: String
    public var startedAt: Int64
    public var expiresAt: Int64?

    // Owner's current location head (from the feed's `location`).
    public var lat: Double?
    public var lng: Double?
    public var accuracy: Double?
    public var altitude: Double?
    public var speed: Double?
    public var heading: Double?
    public var motion: String?
    public var network: String?
    public var batteryLevel: Int?
    public var batteryCharging: Bool?
    public var locRecordedAt: Int64?

    public var updatedAt: Int64

    public init(id: UUID, ownerId: UUID, mode: String, retention: String, startedAt: Int64,
                expiresAt: Int64?, updatedAt: Int64) {
        self.id = id; self.ownerId = ownerId; self.mode = mode; self.retention = retention
        self.startedAt = startedAt; self.expiresAt = expiresAt; self.updatedAt = updatedAt
    }

    /// True when the owner has produced at least one fix (has a plottable position).
    public var hasLocation: Bool { lat != nil && lng != nil }
}

/// The synced people directory (name + avatar), so the UI can label a sharer
/// without a profile call to mvServer. One row per person.
@Model
public final class ContactEntity {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var avatar: String?
    public init(id: UUID, name: String, avatar: String? = nil) {
        self.id = id; self.name = name; self.avatar = avatar
    }
}

/// Single-row persisted feed cursor (the `syncTs` watermark), kept in the same
/// store as the data so it advances transactionally.
@Model
public final class SyncCursorEntity {
    @Attribute(.unique) public var key: String
    public var syncTs: Int64
    public init(key: String = "feed", syncTs: Int64) { self.key = key; self.syncTs = syncTs }
}
