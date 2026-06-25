import Foundation

/// The network boundary. A protocol so the sync engine + UI are testable with a
/// fake (no server), exactly like PulseKit's `PulseTransport` seam.
public protocol TraxTransport: Sendable {
    // Viewer feed (who's sharing with me + where they are now).
    func feed(since: Int64?, limit: Int?) async throws -> FeedDTO
    // Producer.
    func track(_ body: TrackBody) async throws -> TrackAckDTO
    // Directed shares.
    func startShare(_ body: StartShareBody) async throws -> ShareDTO
    func stopShare(id: UUID) async throws
    func stopAllShares() async throws -> CountDTO
    func shares() async throws -> SharesDTO
    // Breadcrumb trail / history.
    func points(ownerId: UUID, since: Int64?, before: Int64?, limit: Int?) async throws -> PointsDTO
    func clearHistory(before: Int64?) async throws -> CountDTO
    // Social-graph directory.
    func contacts() async throws -> [TraxContact]
    /// The caller's own identity from the people directory (for the self-marker).
    func me() async throws -> TraxContact
    // Places + device-published transitions.
    func places() async throws -> [PlaceDTO]
    func createPlace(_ body: PlaceBody) async throws -> PlaceDTO
    func updatePlace(id: UUID, _ body: PlaceBody) async throws -> PlaceDTO
    func deletePlace(id: UUID) async throws
    /// Share a custom place with a friend (co-owned "our spot").
    func sharePlace(id: UUID, viewer: UUID) async throws
    func unsharePlace(id: UUID, viewer: UUID) async throws
    func postTransition(_ body: TransitionBody) async throws
    // Timeline (self).
    func trips(since: Int64?, limit: Int?) async throws -> [TripDTO]
    func visits(since: Int64?, limit: Int?) async throws -> [VisitDTO]
    // Owner-scoped timeline (a friend's journeys; server gates on active share).
    func tripsFor(ownerId: UUID, since: Int64?, limit: Int?) async throws -> [TripDTO]
    func visitsFor(ownerId: UUID, since: Int64?, limit: Int?) async throws -> [VisitDTO]
    /// An owner's own enter/leave events ("read it back"; self, or exact-share friend).
    func transitionsFor(ownerId: UUID, since: Int64?, limit: Int?) async throws -> [TransitionDTO]
}
