import Foundation
import Observation
import SwiftData

/// The driver: pull the viewer feed (who's sharing with me) into the local store,
/// and route mutations (start/stop a share, track a fix) through the transport.
///
/// `@MainActor` + `@Observable`: the UI observes `isLoading` / `lastError` /
/// `outgoing`, and all SwiftData work runs on the main actor via `TraxStore`. Only
/// the transport awaits hop off-main. Coalesces concurrent refreshes.
@MainActor
@Observable
public final class TraxSync {
    public private(set) var isLoading = false
    public private(set) var lastError: String?
    /// My active outgoing shares (who I'm sharing with). Held in memory — small,
    /// no delta/persistence needed; refreshed alongside the feed.
    public private(set) var outgoing: [ShareDTO] = []
    /// Recent place enter/leave events from people sharing with me (newest first,
    /// capped). Accumulated from feed pages; transient (not persisted).
    public private(set) var recentTransitions: [TransitionDTO] = []

    /// The selected sharer's recent breadcrumb (drawn on the map when you tap a
    /// member). Server enforces that you have an active share from them.
    public private(set) var selectedTrail: [PointDTO] = []
    /// The open member card's journeys (that friend's trips + visits, today).
    public private(set) var memberTrips: [TripDTO] = []
    public private(set) var memberVisits: [VisitDTO] = []

    /// The day's timeline (self), loaded on demand for the Timeline tab.
    public private(set) var timelineTrips: [TripDTO] = []
    public private(set) var timelineVisits: [VisitDTO] = []
    public private(set) var timelinePoints: [PointDTO] = []

    public let currentUserID: UUID
    private let transport: any TraxTransport
    private let store: TraxStore
    private var isRefreshing = false

    /// The SwiftData container backing this sync's store. Exposed so pushed screens
    /// can attach it to their `@Query` environment.
    public var container: ModelContainer { store.container }

    public init(transport: any TraxTransport, store: TraxStore, currentUserID: UUID) {
        self.transport = transport
        self.store = store
        self.currentUserID = currentUserID
    }

    public convenience init(config: TraxConfig, store: TraxStore) {
        self.init(transport: config.transport, store: store, currentUserID: config.currentUserID)
    }

    // MARK: - Reads

    /// Pull everything new since the persisted cursor, draining pages until the
    /// server reports no more (or the cursor stops advancing).
    public func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        isLoading = true
        defer { isRefreshing = false; isLoading = false }

        var since = store.cursor()
        do {
            while true {
                let page = try await transport.feed(since: since > 0 ? since : nil, limit: nil)
                store.applyFeedPage(page)
                if let trs = page.transitions, !trs.isEmpty { mergeTransitions(trs) }
                guard page.hasMore, page.syncTs > since else { break }
                since = page.syncTs
            }
            lastError = nil
        } catch is CancellationError {
            // Benign — the next refresh covers it.
        } catch {
            lastError = describe(error)
        }
    }

    /// Refresh my outgoing shares (the "who I'm sharing with" list + stop controls).
    public func refreshOutgoing() async {
        do {
            outgoing = try await transport.shares().outgoing
            lastError = nil
        } catch is CancellationError {
        } catch {
            lastError = describe(error)
        }
    }

    /// The caller's own identity from the people directory (name + avatar).
    public func me() async throws -> TraxContact {
        try await transport.me()
    }

    /// Fetch the people directory (friends + my own entry) into the local store
    /// for labelling sharers and populating the share picker.
    public func loadContacts() async {
        do {
            let contacts = try await transport.contacts()
            store.upsertContacts(contacts)
            if let me = try? await transport.me() { store.upsertContact(me) }
            lastError = nil
        } catch is CancellationError {
        } catch {
            lastError = describe(error)
        }
    }

    // MARK: - Mutations

    @discardableResult
    public func startShare(viewer: UUID, mode: String = "live",
                           retention: String = "indefinite", expiresInSeconds: Int? = nil) async throws -> ShareDTO {
        let dto = try await transport.startShare(
            StartShareBody(viewer: viewer, mode: mode, retention: retention, expiresIn: expiresInSeconds))
        await refreshOutgoing()
        return dto
    }

    public func stopShare(id: UUID) async throws {
        try await transport.stopShare(id: id)
        await refreshOutgoing()
    }

    public func stopAll() async throws {
        _ = try await transport.stopAllShares()
        await refreshOutgoing()
    }

    /// Producer hook: ingest one fix.
    @discardableResult
    public func track(_ body: TrackBody) async throws -> TrackAckDTO {
        try await transport.track(body)
    }

    // MARK: - Places (the user's own)

    /// Pull the user's places into the local store (drives the Places tab + the
    /// geofence monitor).
    public func loadPlaces() async {
        do {
            let places = try await transport.places()
            store.replacePlaces(places)
            lastError = nil
        } catch is CancellationError {
        } catch {
            lastError = describe(error)
        }
    }

    @discardableResult
    public func createPlace(_ body: PlaceBody) async throws -> PlaceDTO {
        let p = try await transport.createPlace(body)
        await loadPlaces()
        return p
    }

    @discardableResult
    public func updatePlace(id: UUID, _ body: PlaceBody) async throws -> PlaceDTO {
        let p = try await transport.updatePlace(id: id, body)
        await loadPlaces()
        return p
    }

    public func deletePlace(id: UUID) async throws {
        try await transport.deletePlace(id: id)
        await loadPlaces()
    }

    /// Geofence-monitor hook: publish a device-detected enter/leave. Fire-and-log
    /// — the server owns debounce + fan-out.
    public func postTransition(placeID: UUID, event: String, lat: Double? = nil, lng: Double? = nil) async {
        do {
            try await transport.postTransition(TransitionBody(placeId: placeID, event: event, lat: lat, lng: lng))
        } catch is CancellationError {
        } catch {
            lastError = describe(error)
        }
    }

    // MARK: - Sharer trail (selected member's recent breadcrumb)

    /// Load a sharer's breadcrumb for an optional time window (a specific
    /// journey's [since, before)). Server gates on an active share from them.
    public func loadTrail(ownerID: UUID, since: Int64? = nil, before: Int64? = nil) async {
        do {
            selectedTrail = try await transport.points(ownerId: ownerID, since: since, before: before, limit: 500).points
            lastError = nil
        } catch is CancellationError {
        } catch {
            lastError = describe(error)
        }
    }

    public func clearTrail() { selectedTrail = [] }

    /// Load the open member card's journeys (their trips + visits for today).
    public func loadMemberTimeline(ownerID: UUID) async {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let sinceMs = Int64(startOfDay.timeIntervalSince1970 * 1000)
        do {
            memberTrips = try await transport.tripsFor(ownerId: ownerID, since: sinceMs, limit: 200)
            memberVisits = try await transport.visitsFor(ownerId: ownerID, since: sinceMs, limit: 200)
            lastError = nil
        } catch is CancellationError {
        } catch {
            lastError = describe(error)
        }
    }

    /// Clear the member card's state (journeys + trail) when it closes.
    public func clearMember() {
        memberTrips = []; memberVisits = []; selectedTrail = []
    }

    // MARK: - Timeline (self, per-day)

    /// Load my trips + visits + raw points for the calendar day containing `day`.
    public func loadTimeline(day: Date) async {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: day)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        let sinceMs = Int64(startOfDay.timeIntervalSince1970 * 1000)
        let endMs = Int64(endOfDay.timeIntervalSince1970 * 1000)
        do {
            // Server returns since>=; filter to the day's upper bound client-side.
            let trips = try await transport.trips(since: sinceMs, limit: 1000).filter { $0.startTs < endMs }
            let visits = try await transport.visits(since: sinceMs, limit: 1000).filter { $0.startTs < endMs }
            let pts = try await transport.points(ownerId: currentUserID, since: sinceMs, before: endMs, limit: 2000)
            timelineTrips = trips
            timelineVisits = visits
            timelinePoints = pts.points
            lastError = nil
        } catch is CancellationError {
        } catch {
            lastError = describe(error)
        }
    }

    // MARK: - helpers

    /// Merge new transitions (newest first, dedup by id, cap 50).
    private func mergeTransitions(_ incoming: [TransitionDTO]) {
        var seen = Set(recentTransitions.map(\.id))
        var merged = recentTransitions
        for t in incoming where !seen.contains(t.id) {
            merged.append(t); seen.insert(t.id)
        }
        recentTransitions = Array(merged.sorted { $0.createdAt > $1.createdAt }.prefix(50))
    }

    private func describe(_ error: Error) -> String {
        if let te = error as? TraxError { return te.description }
        return String(describing: error)
    }
}
