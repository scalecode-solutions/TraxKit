import SwiftUI
import CoreLocation

// The relationship-shaped embedding API. A Trax share IS a conversation — a dyad
// between two users — so the host (e.g. Clingy, per-1:1-conversation) asks "what's
// the state of my location relationship with this person?" and gets both
// directions plus recent events. Backed by the already-synced local store + the
// feed; reads are cheap (no per-call network), mirroring PulseKit's per-user
// status store. The host holds one instance and injects it.

/// My outgoing share to a partner (I'm letting them see me).
public struct TraxShareInfo: Sendable, Hashable {
    public let shareID: UUID
    public let precision: String   // exact | place | approx
    public let mode: String        // live | breadcrumb
    public let expiresAt: Int64?   // epoch ms; nil = until I stop
}

/// A partner's current location AS PRESENTED TO ME (precision already applied by
/// the server) — the incoming side of the relationship.
public struct TraxLocationSummary: Sendable {
    public let coordinate: CLLocationCoordinate2D?  // nil = no presented fix (place-away / no fix)
    public let placeName: String?
    public let atPlace: Bool
    public let precision: String
    public let battery: Int?
    public let batteryCharging: Bool
    public let lastUpdatedMs: Int64?
    public let isLive: Bool
}

/// The full location facet of a 1:1 relationship.
public struct TraxRelationship: Sendable {
    public let partnerID: UUID
    public let outgoing: TraxShareInfo?       // I share with them
    public let incoming: TraxLocationSummary? // they share with me
    public var iShare: Bool { outgoing != nil }
    public var theyShare: Bool { incoming != nil }
    public var isMutual: Bool { outgoing != nil && incoming != nil }
}

@MainActor
@Observable
public final class TraxLocationStore {
    private let sync: TraxSync
    private let store: TraxStore

    public init(sync: TraxSync, store: TraxStore) {
        self.sync = sync
        self.store = store
    }

    /// My outgoing share to `partner`, if any (observed via `sync.outgoing`).
    public func outgoingShare(to partner: UUID) -> TraxShareInfo? {
        sync.outgoing.first { $0.viewerId == partner }.map {
            TraxShareInfo(shareID: $0.id, precision: $0.precision, mode: $0.mode, expiresAt: $0.expiresAt)
        }
    }

    /// `partner`'s current presented location, if they're sharing with me.
    public func summary(for partner: UUID) -> TraxLocationSummary? {
        guard let s = store.incomingShare(ownerID: partner) else { return nil }
        let st = s.status()
        let coord = (s.lat != nil && s.lng != nil)
            ? CLLocationCoordinate2D(latitude: s.lat!, longitude: s.lng!) : nil
        return TraxLocationSummary(
            coordinate: coord, placeName: s.placeName, atPlace: s.atPlace, precision: s.precision,
            battery: s.batteryLevel, batteryCharging: s.batteryCharging ?? false,
            lastUpdatedMs: s.locRecordedAt, isLive: st.isLive)
    }

    /// Both directions of the relationship in one call (what a conversation header reads).
    public func relationship(with partner: UUID) -> TraxRelationship {
        TraxRelationship(partnerID: partner, outgoing: outgoingShare(to: partner), incoming: summary(for: partner))
    }

    /// `partner`'s recent enter/leave events visible to me (from the live feed) —
    /// the events the chat bridge projects into the thread for that partner.
    public func recentTransitions(with partner: UUID, limit: Int = 20) -> [TransitionDTO] {
        Array(sync.recentTransitions.filter { $0.ownerId == partner }.prefix(limit))
    }

    /// My OWN enter/leave events read back from mvTrax (durable) — the chat bridge
    /// projects these into my side of the thread / backfills on a fresh device.
    public func myTransitions(since: Int64? = nil, limit: Int? = nil) async -> [TransitionDTO] {
        await sync.transitions(ownerID: sync.currentUserID, since: since, limit: limit)
    }

    /// Fold a `partner`'s durable enter/leave history (gated to what I'm allowed to
    /// see) into the live `recentTransitions` buffer — so a chat thread's backfill of
    /// past arrivals rides the SAME @Observable path as live events, rather than a
    /// separate source the host has to merge in the view (which won't reliably
    /// surface in a UICollectionView landing async after the initial build).
    public func backfill(with partner: UUID, limit: Int? = nil) async {
        await sync.backfillTransitions(ownerID: partner, limit: limit)
    }
}
