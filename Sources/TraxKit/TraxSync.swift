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
    public func startShare(viewer: UUID, mode: String = "live", retention: String = "indefinite",
                           precision: String = "exact", expiresInSeconds: Int? = nil) async throws -> ShareDTO {
        let dto = try await transport.startShare(
            StartShareBody(viewer: viewer, mode: mode, retention: retention,
                           precision: precision, expiresIn: expiresInSeconds))
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

    /// Share a custom place with a friend (co-owned "our spot").
    public func sharePlace(id: UUID, viewer: UUID) async throws {
        try await transport.sharePlace(id: id, viewer: viewer)
        await loadPlaces()
    }

    public func unsharePlace(id: UUID, viewer: UUID) async throws {
        try await transport.unsharePlace(id: id, viewer: viewer)
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

    // MARK: - Timeline (any owner, per-day)

    /// One day's curated timeline for an owner (self or a friend who shares with
    /// you). Returned (not stored) so each Timeline screen owns its own state and
    /// two screens never collide. Friend reads are server-gated on an active share.
    public func timeline(ownerID: UUID, day: Date) async -> TimelineDay {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: day)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        let sinceMs = Int64(startOfDay.timeIntervalSince1970 * 1000)
        let endMs = Int64(endOfDay.timeIntervalSince1970 * 1000)
        do {
            let trips = try await transport.tripsFor(ownerId: ownerID, since: sinceMs, limit: 1000).filter { $0.startTs < endMs }
            let visits = try await transport.visitsFor(ownerId: ownerID, since: sinceMs, limit: 1000).filter { $0.startTs < endMs }
            let pts = try await transport.points(ownerId: ownerID, since: sinceMs, before: endMs, limit: 2000)
            lastError = nil
            return TimelineDay(trips: trips, visits: visits, points: pts.points)
        } catch is CancellationError {
            return TimelineDay()
        } catch {
            lastError = describe(error)
            return TimelineDay()
        }
    }

    /// An owner's own enter/leave events (newest first). Pass `currentUserID` for
    /// your own back-read; a friend's id works only with an active exact share.
    /// The "read it back" path the chat bridge projects into the thread.
    public func transitions(ownerID: UUID, since: Int64? = nil, limit: Int? = nil) async -> [TransitionDTO] {
        do {
            let trs = try await transport.transitionsFor(ownerId: ownerID, since: since, limit: limit)
            lastError = nil
            return trs
        } catch is CancellationError {
            return []
        } catch {
            lastError = describe(error)
            return []
        }
    }

    /// Fetch an owner's durable enter/leave history and fold it into the live
    /// `recentTransitions` buffer — so a chat thread's backfill of past arrivals
    /// rides the SAME @Observable path as the live feed, instead of a second source
    /// the host has to merge separately (which won't reliably refresh the UI).
    public func backfillTransitions(ownerID: UUID, limit: Int? = nil) async {
        let trs = await transitions(ownerID: ownerID, since: nil, limit: limit)
        if !trs.isEmpty { mergeTransitions(trs) }
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
