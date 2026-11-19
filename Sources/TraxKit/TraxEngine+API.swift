import Foundation
import CoreLocation

// The engine's public surface: everything a host (and the kit's own views)
// reads or does goes through here. State is published as values, safe to
// read in a view body; verbs are named for what they do, not the RPC they
// call. `sync` and `bridge` stay internal.

/// How exactly a share presents my location to its viewer.
public enum TraxPrecision: String, Sendable, CaseIterable {
    case exact, place, approx
}

/// One of my live outgoing shares: who sees me, and until when.
public struct TraxOutgoingShare: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let viewerID: UUID
    /// nil when the server sent a precision this kit doesn't know.
    public let precision: TraxPrecision?
    public let startedAt: Date
    /// nil = until I stop.
    public let expiresAt: Date?

    init(_ s: ShareDTO) {
        id = s.id; viewerID = s.viewerId; precision = TraxPrecision(rawValue: s.precision)
        startedAt = Date(epochMs: s.startedAt)
        expiresAt = s.expiresAt.map(Date.init(epochMs:))
    }
}

/// What a place is to its owner. Unknown kinds from a newer server read as custom.
public enum TraxPlaceKind: String, Sendable, CaseIterable {
    case home, work, custom
}

/// A place visible to me: mine, or one a friend shares with me.
public struct TraxPlace: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let ownerID: UUID
    public let kind: TraxPlaceKind
    public let name: String
    public let emoji: String?
    public let address: String?
    public let latitude: Double
    public let longitude: Double
    public let radiusM: Int
    /// The friends I share it with (my places only).
    public let sharedWith: [UUID]
    public let isMine: Bool
    public let updatedAt: Date

    public var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    public var isShared: Bool { !sharedWith.isEmpty }

    init(_ p: PlaceSnapshot, me: UUID) {
        id = p.id; ownerID = p.ownerID; kind = TraxPlaceKind(rawValue: p.type) ?? .custom
        name = p.name; emoji = p.emoji; address = p.address
        latitude = p.lat; longitude = p.lng; radiusM = p.radiusM
        sharedWith = p.sharedWith; isMine = p.ownerID == me; updatedAt = Date(epochMs: p.updatedAt)
    }
}

/// What a place editor hands back: a new place, or new values for one.
public struct TraxPlaceDraft: Sendable, Hashable {
    public var kind: TraxPlaceKind
    public var name: String
    public var emoji: String?
    public var latitude: Double
    public var longitude: Double
    public var radiusM: Int
    public var address: String?

    public init(kind: TraxPlaceKind = .custom, name: String, emoji: String? = nil, latitude: Double,
                longitude: Double, radiusM: Int = 150, address: String? = nil) {
        self.kind = kind; self.name = name; self.emoji = emoji; self.latitude = latitude; self.longitude = longitude
        self.radiusM = radiusM; self.address = address
    }

    var body: PlaceBody {
        PlaceBody(name: name, type: kind.rawValue, lat: latitude, lng: longitude, radiusM: radiusM, emoji: emoji, address: address)
    }
}

extension Date {
    init(epochMs: Int64) { self.init(timeIntervalSince1970: TimeInterval(epochMs) / 1000) }
}

public extension TraxEngine {
    // MARK: State

    var currentUserID: UUID { sync.currentUserID }
    /// Whether my location is going out to anyone now.
    var isSharing: Bool { sync.isSharing }
    var lastError: String? { sync.lastError }
    /// Moves whenever the cached data does.
    var revision: Int { sync.revision }

    /// Friends and me, by id: names and avatars for every row.
    var people: [UUID: TraxContact] { Dictionary(sync.contacts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    var outgoingShares: [TraxOutgoingShare] { sync.outgoing.map(TraxOutgoingShare.init) }

    /// Every place visible to me, by name.
    var places: [TraxPlace] {
        sync.placeSnapshots.map { TraxPlace($0, me: sync.currentUserID) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Both directions with one person: my share to them, their location to me.
    func relationship(with person: UUID) -> TraxRelationship { bridge.relationship(with: person) }
    /// My places I share with `person`.
    func sharedPlaces(with person: UUID) -> [TraxSharedPlace] { bridge.sharedPlaces(with: person) }
    /// `person`'s recent arrivals and departures visible to me, newest first.
    func recentTransitions(with person: UUID, limit: Int = 20) -> [TransitionDTO] {
        bridge.recentTransitions(with: person, limit: limit)
    }
    /// My own recent arrivals and departures, newest first (durable across launches).
    func myRecentTransitions(limit: Int = 20) -> [TransitionDTO] { bridge.myRecentTransitions(limit: limit) }

    // MARK: Sharing

    /// Start my share with `person`, or change the live one: the server updates
    /// an active share in place (precision and expiry), so this is also how a
    /// pair-settings screen changes precision or duration. `duration` nil = until
    /// I stop (it clears an existing expiry).
    func startSharing(with person: UUID, precision: TraxPrecision = .exact, duration: Duration? = nil) async throws {
        try await sync.startShare(viewer: person, precision: precision.rawValue,
                                  expiresInSeconds: duration.map { Int($0.components.seconds) })
    }

    /// Stop every share I have pointed at `person`. No share = nothing to do.
    func stopSharing(with person: UUID) async throws {
        for s in sync.outgoing where s.viewerId == person { try await sync.stopShare(id: s.id) }
    }

    func stopAllSharing() async throws { try await sync.stopAll() }

    // MARK: Places

    @discardableResult
    func addPlace(_ draft: TraxPlaceDraft) async throws -> TraxPlace {
        let dto = try await sync.createPlace(draft.body)
        pushRegions()
        return places.first { $0.id == dto.id } ?? TraxPlace(fallback: dto, me: currentUserID)
    }

    func updatePlace(_ id: UUID, _ draft: TraxPlaceDraft) async throws {
        try await sync.updatePlace(id: id, draft.body)
        pushRegions()
    }

    func deletePlace(_ id: UUID) async throws {
        try await sync.deletePlace(id: id)
        pushRegions()
    }

    func sharePlace(_ id: UUID, with person: UUID) async throws { try await sync.sharePlace(id: id, viewer: person) }
    func unsharePlace(_ id: UUID, with person: UUID) async throws { try await sync.unsharePlace(id: id, viewer: person) }

    // MARK: History

    /// One day of `owner`'s timeline: mine, or a friend's who shares exactly with me.
    func timeline(of owner: UUID, day: Date) async -> TimelineDay { await sync.timeline(ownerID: owner, day: day) }
    /// `owner`'s arrivals and departures from the server, newest first.
    func transitions(of owner: UUID, since: Date? = nil, limit: Int? = nil) async -> [TransitionDTO] {
        await sync.transitions(ownerID: owner, since: since.map { Int64($0.timeIntervalSince1970 * 1000) }, limit: limit)
    }
    /// Fold `person`'s server history into `recentTransitions(with:)`.
    func backfillTransitions(with person: UUID, limit: Int? = nil) async {
        await sync.backfillTransitions(ownerID: person, limit: limit)
    }

    /// Delete my location history before `before` (nil = all of it): points,
    /// visits, trips and my arrivals/departures, on the server and on this
    /// device. Returns how many points went.
    @discardableResult
    func clearHistory(before: Date? = nil) async throws -> Int { try await sync.clearMyHistory(before: before) }

    /// My own name and avatar from the people directory.
    func me() async throws -> TraxContact { try await sync.me() }
}

extension TraxPlace {
    /// A place the server just created, before the reload that follows lands.
    init(fallback p: PlaceDTO, me: UUID) {
        id = p.id; ownerID = p.ownerId; kind = TraxPlaceKind(rawValue: p.type) ?? .custom
        name = p.name; emoji = p.emoji; address = p.address
        latitude = p.lat; longitude = p.lng; radiusM = p.radiusM
        sharedWith = p.sharedWith ?? []; isMine = p.ownerId == me; updatedAt = Date(epochMs: p.updatedAt)
    }
}
