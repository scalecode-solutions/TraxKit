import Foundation
@testable import TraxKit

/// A scriptable, in-memory `TraxTransport` for engine tests: no server. Feed
/// pages, shares and places are whatever the test sets; any call can be made to
/// fail; every call is recorded.
actor FakeTraxTransport: TraxTransport {
    // Scripted state.
    var feedPages: [FeedDTO] = []
    var outgoing: [ShareDTO] = []
    var placeList: [PlaceDTO] = []
    var contactList: [TraxContact] = []
    var meContact = TraxContact(id: UUID(), name: "Me")
    var trackAck = TrackAckDTO(ok: true, shares: 1, ts: 0)
    /// Calls named here throw this error (once per listed occurrence).
    var failures: [String: [Error]] = [:]
    /// call name → (1-based call number, error): that one call fails.
    private var failOnNumber: [String: (Int, Error)] = [:]
    /// Calls named here suspend until `release(_:)`.
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var gated: Set<String> = []

    // Recorded calls.
    private(set) var calls: [String] = []
    private(set) var tracked: [TrackBody] = []
    private(set) var postedTransitions: [TransitionBody] = []

    // MARK: scripting

    func queueFeed(_ page: FeedDTO) { feedPages.append(page) }
    func setOutgoing(_ s: [ShareDTO]) { outgoing = s }
    func setPlaces(_ p: [PlaceDTO]) { placeList = p }
    func setContacts(_ c: [TraxContact]) { contactList = c }
    func setMe(_ c: TraxContact) { meContact = c }
    func setTrackAck(_ a: TrackAckDTO) { trackAck = a }
    func fail(_ call: String, with error: Error, times: Int = 1) {
        failures[call, default: []].append(contentsOf: Array(repeating: error, count: times))
    }
    /// Only the `number`th call of `call` (counting from 1) fails.
    func fail(_ call: String, with error: Error, onCallNumber number: Int) {
        failOnNumber[call] = (number, error)
    }
    /// The next `call` suspends until `release(call)`.
    func hold(_ call: String) { gated.insert(call) }
    func release(_ call: String) {
        gated.remove(call)
        gates.removeValue(forKey: call)?.resume()
    }
    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }

    private func enter(_ call: String) async throws {
        calls.append(call)
        if gated.contains(call) {
            await withCheckedContinuation { gates[call] = $0 }
        }
        if let (n, e) = failOnNumber[call], calls.filter({ $0 == call }).count == n {
            throw e
        }
        if var queue = failures[call], !queue.isEmpty {
            let e = queue.removeFirst()
            failures[call] = queue
            throw e
        }
    }

    // MARK: TraxTransport

    /// What each feed request sent.
    private(set) var feedRequests: [(since: Int64?, rev: Int64?, loadFrom: Int64?)] = []
    func feed(since: Int64?, rev: Int64?, loadFrom: Int64?, limit: Int?) async throws -> FeedDTO {
        try await enter("feed")
        feedRequests.append((since, rev, loadFrom))
        guard !feedPages.isEmpty else {
            return FeedDTO(shares: [], syncTs: since ?? 0, hasMore: false, stoppedIds: [])
        }
        return feedPages.removeFirst()
    }
    func track(_ body: TrackBody) async throws -> TrackAckDTO {
        try await enter("track")
        tracked.append(body)
        return trackAck
    }
    /// Each startShare body, in order.
    private(set) var startBodies: [StartShareBody] = []
    var lastStartShare: StartShareBody? { startBodies.last }
    /// Like the server: a live share to the same viewer is updated in place.
    func startShare(_ body: StartShareBody) async throws -> ShareDTO {
        try await enter("startShare")
        startBodies.append(body)
        let id = outgoing.first { $0.viewerId == body.viewer }?.id ?? UUID()
        let s = Fixtures.share(id: id, owner: meContact.id, viewer: body.viewer, precision: body.precision ?? "exact",
                               expiresAt: body.expiresIn.map { Fixtures.nowMs(TimeInterval($0)) })
        outgoing.removeAll { $0.viewerId == body.viewer }
        outgoing.append(s)
        return s
    }
    func stopShare(id: UUID) async throws {
        try await enter("stopShare")
        outgoing.removeAll { $0.id == id }
    }
    func stopAllShares() async throws -> CountDTO {
        try await enter("stopAllShares")
        defer { outgoing = [] }
        return CountDTO(count: Int64(outgoing.count))
    }
    func shares() async throws -> SharesDTO {
        try await enter("shares")
        return SharesDTO(outgoing: outgoing, incoming: [])
    }
    func points(ownerId: UUID, since: Int64?, before: Int64?, limit: Int?) async throws -> PointsDTO {
        try await enter("points")
        return PointsDTO(ownerId: ownerId, points: [])
    }
    func clearHistory(before: Int64?) async throws -> CountDTO {
        try await enter("clearHistory")
        return CountDTO(count: 0)
    }
    func contacts() async throws -> [TraxContact] {
        try await enter("contacts")
        return contactList
    }
    func me() async throws -> TraxContact {
        try await enter("me")
        return meContact
    }
    func places() async throws -> [PlaceDTO] {
        try await enter("places")
        return placeList
    }
    private(set) var lastPlaceBody: PlaceBody?
    func createPlace(_ body: PlaceBody) async throws -> PlaceDTO {
        try await enter("createPlace")
        lastPlaceBody = body
        let f = Fixtures.place(owner: meContact.id, name: body.name, lat: body.lat, lng: body.lng)
        let p = PlaceDTO(id: f.id, ownerId: f.ownerId, name: f.name, type: body.type, lat: f.lat, lng: f.lng,
                         radiusM: body.radiusM, emoji: body.emoji, address: body.address, sharedWith: [],
                         createdAt: f.createdAt, updatedAt: f.updatedAt)
        placeList.append(p)
        return p
    }
    func updatePlace(id: UUID, _ body: PlaceBody) async throws -> PlaceDTO {
        try await enter("updatePlace")
        return Fixtures.place(id: id, owner: meContact.id, name: body.name, lat: body.lat, lng: body.lng)
    }
    func deletePlace(id: UUID) async throws {
        try await enter("deletePlace")
        placeList.removeAll { $0.id == id }
    }
    func sharePlace(id: UUID, viewer: UUID) async throws {
        try await enter("sharePlace")
        setSharedWith(id) { if !$0.contains(viewer) { $0.append(viewer) } }
    }
    func unsharePlace(id: UUID, viewer: UUID) async throws {
        try await enter("unsharePlace")
        setSharedWith(id) { $0.removeAll { $0 == viewer } }
    }
    private func setSharedWith(_ id: UUID, _ change: (inout [UUID]) -> Void) {
        guard let i = placeList.firstIndex(where: { $0.id == id }) else { return }
        let p = placeList[i]
        var w = p.sharedWith ?? []
        change(&w)
        placeList[i] = PlaceDTO(id: p.id, ownerId: p.ownerId, name: p.name, type: p.type, lat: p.lat, lng: p.lng,
                                radiusM: p.radiusM, emoji: p.emoji, address: p.address, sharedWith: w,
                                createdAt: p.createdAt, updatedAt: p.updatedAt)
    }
    func postTransition(_ body: TransitionBody) async throws {
        try await enter("postTransition")
        postedTransitions.append(body)
    }
    func trips(since: Int64?, before: Int64?, limit: Int?) async throws -> [TripDTO] { try await enter("trips"); return [] }
    func visits(since: Int64?, before: Int64?, limit: Int?) async throws -> [VisitDTO] { try await enter("visits"); return [] }
    /// The (since, before) bounds each owner timeline read asked for.
    private(set) var timelineBounds: [(since: Int64?, before: Int64?)] = []
    func tripsFor(ownerId: UUID, since: Int64?, before: Int64?, limit: Int?) async throws -> [TripDTO] {
        try await enter("tripsFor"); timelineBounds.append((since, before)); return []
    }
    func visitsFor(ownerId: UUID, since: Int64?, before: Int64?, limit: Int?) async throws -> [VisitDTO] {
        try await enter("visitsFor"); timelineBounds.append((since, before)); return []
    }
    var transitionsForResult: [TransitionDTO] = []
    func setTransitionsFor(_ t: [TransitionDTO]) { transitionsForResult = t }
    func transitionsFor(ownerId: UUID, since: Int64?, limit: Int?) async throws -> [TransitionDTO] {
        try await enter("transitionsFor")
        return transitionsForResult
    }
}

/// Synthetic values for tests: random ids, made-up coordinates.
enum Fixtures {
    static func nowMs(_ offset: TimeInterval = 0) -> Int64 { Int64((Date().timeIntervalSince1970 + offset) * 1000) }

    static func share(id: UUID = UUID(), owner: UUID, viewer: UUID, precision: String = "exact",
                      lat: Double? = nil, lng: Double? = nil, at: Int64? = nil,
                      expiresAt: Int64? = nil) -> ShareDTO {
        let loc = lat.map { LocationDTO(lat: $0, lng: lng ?? 0, batteryLevel: 80, recordedAt: at ?? nowMs()) }
        return ShareDTO(id: id, ownerId: owner, viewerId: viewer, mode: "live", retention: "indefinite",
                        precision: precision, startedAt: nowMs(-3600), expiresAt: expiresAt, location: loc,
                        fuzzRadiusM: nil, placeName: nil, placeEmoji: nil, atPlace: nil)
    }

    static func page(_ shares: [ShareDTO], stopped: [UUID] = [], transitions: [TransitionDTO]? = nil,
                     syncTs: Int64 = nowMs(), hasMore: Bool = false) -> FeedDTO {
        FeedDTO(shares: shares, transitions: transitions, syncTs: syncTs, hasMore: hasMore, stoppedIds: stopped)
    }

    static func place(id: UUID = UUID(), owner: UUID, name: String, lat: Double, lng: Double,
                      sharedWith: [UUID] = []) -> PlaceDTO {
        PlaceDTO(id: id, ownerId: owner, name: name, type: "custom", lat: lat, lng: lng, radiusM: 100,
                 emoji: nil, address: nil, sharedWith: sharedWith, createdAt: nowMs(), updatedAt: nowMs())
    }

    static func transition(id: UUID = UUID(), owner: UUID, place: UUID, name: String = "Spot",
                           event: String = "enter", at: Int64 = nowMs()) -> TransitionDTO {
        TransitionDTO(id: id, ownerId: owner, placeId: place, placeName: name, placeEmoji: nil,
                      event: event, createdAt: at)
    }
}
