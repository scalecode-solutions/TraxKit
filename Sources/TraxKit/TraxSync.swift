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
            report(error)
        }
    }

    /// Refresh my outgoing shares (the "who I'm sharing with" list + stop controls).
    public func refreshOutgoing() async {
        do {
            outgoing = try await transport.shares().outgoing
            lastError = nil
        } catch is CancellationError {
        } catch {
            report(error)
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
            report(error)
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

    /// Low-level: post one assembled track point.
    @discardableResult
    public func track(_ body: TrackBody) async throws -> TrackAckDTO {
        try await transport.track(body)
    }

    private var lastPostedAt: Date?

    /// The kit's tracking demand for the host, derived purely from share state —
    /// never leaks *who* is watching. The host decides how to satisfy it.
    /// (No active-watcher granularity yet, so any live share → `.continuous`.)
    public var trackingDemand: TraxTrackingDemand { outgoing.isEmpty ? .off : .continuous }

    /// Ingest one enriched fix from the host and post it to mvTrax — but ONLY while
    /// I'm sharing, throttled. This is the producer-collapse: the host owns the
    /// device + the cadence tier; the kit just gates on sharing + throttles uploads.
    public func ingestFix(_ fix: TraxFix, minInterval: TimeInterval = 5) {
        guard !outgoing.isEmpty else { return }                       // not sharing → nothing to post
        if let last = lastPostedAt, Date().timeIntervalSince(last) < minInterval { return }
        lastPostedAt = Date()
        let body = TrackBody(
            lat: fix.lat, lng: fix.lng, accuracy: fix.horizontalAccuracy,
            altitude: fix.altitude, speed: fix.speed, heading: fix.course,
            motion: fix.motion, batteryLevel: fix.batteryLevel, batteryCharging: fix.batteryCharging,
            clientTs: Int64(fix.timestamp.timeIntervalSince1970 * 1000))
        Task { try? await track(body) }
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
            report(error)
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
    /// — the server owns debounce + fan-out. Also records MY OWN crossing locally so
    /// my side of the thread shows "You arrived at X" immediately (the feed never
    /// delivers my own transitions back to me).
    public func postTransition(placeID: UUID, event: String, lat: Double? = nil, lng: Double? = nil) async {
        recordOwnTransition(placeID: placeID, event: event)
        do {
            try await transport.postTransition(TransitionBody(placeId: placeID, event: event, lat: lat, lng: lng))
        } catch is CancellationError {
        } catch {
            report(error)
        }
    }

    /// Fold my own crossing into the live (observable) buffer + the durable store,
    /// resolving the place from my local set — so the owner sees their own arrival
    /// without waiting on (or ever receiving) a feed echo.
    private func recordOwnTransition(placeID: UUID, event: String) {
        guard let place = store.allPlaces().first(where: { $0.id == placeID }) else { return }
        let dto = TransitionDTO(
            id: UUID(), ownerId: currentUserID, placeId: placeID,
            placeName: place.name, placeEmoji: place.emoji, event: event,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000))
        store.upsertTransition(dto); store.save()
        mergeTransitions([dto])
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
            report(error)
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
            report(error)
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

    /// Route a caught error to `lastError`, but swallow transient auth blips.
    /// A momentarily-missing/expired token (the host refreshes on its own rail)
    /// would otherwise flash a raw `CodeUnauthenticated` RPC dump in the UI's red
    /// banner every time a sync lands in the refresh gap; the next cycle clears it
    /// anyway. Treat it as benign — like `CancellationError` — and don't alarm.
    private func report(_ error: Error) {
        if isTransientAuth(error) { return }
        report(error)
    }

    /// Both the missing-token guard and the server's `.unauthenticated` rejection
    /// collapse onto `TraxTransportError.notAuthenticated` in the transport, so a
    /// single check covers both flavors.
    private func isTransientAuth(_ error: Error) -> Bool {
        if case TraxTransportError.notAuthenticated = error { return true }
        return false
    }

    private func describe(_ error: Error) -> String {
        if let te = error as? TraxError { return te.description }
        return String(describing: error)
    }
}
