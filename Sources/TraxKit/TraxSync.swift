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

    /// Bumped whenever the cached data changes (a feed page, places, contacts,
    /// my own crossings, a wipe). Anything that reads the store from a view
    /// touches this first, so the view re-renders when the store moves.
    public private(set) var revision = 0
    /// Each sharer's current presented location, published as values (the
    /// bridge reads these; nothing fetches inside a view body).
    private(set) var incoming: [UUID: IncomingShareSnapshot] = [:]
    /// Places visible to me, published as values.
    private(set) var placeSnapshots: [PlaceSnapshot] = []
    private var publishedChanges = -1

    /// Bumped by `invalidate()` (stop) and `wipe()`: work that started before
    /// must not write after. Every read that awaits the network checks it.
    private(set) var generation = 0
    /// Set by `wipe()`, cleared by `resume()`: after a sign-out wipe nothing in
    /// flight or newly triggered may write to the store until the next start.
    private(set) var isWiped = false
    /// The refresh running now; concurrent callers wait for it.
    private var inflight: Task<Void, Never>?
    private var refreshAgain = false

    /// Drop the results of everything in flight (the engine stopped).
    func invalidate() { generation += 1 }

    /// Writes are allowed again (the engine started).
    func resume() { isWiped = false }

    /// Sign-out: discard in-flight work, empty the store and the in-memory state.
    func wipe() {
        invalidate()
        isWiped = true
        store.wipeAll()
        outgoing = []
        recentTransitions = []
        pollFailureStreaks = [:]
        lastError = nil
        lastPostedAt = nil
        pendingTrack = nil
        lastTrackAck = nil
        publish()
    }

    /// True while results started at `gen` may still be written.
    private func current(_ gen: Int) -> Bool { gen == generation && !isWiped }

    public let currentUserID: UUID
    private let transport: any TraxTransport
    private let store: TraxStore

    /// Consecutive-failure streaks for the POLL-driven reads (feed / outgoing /
    /// contacts / places), keyed per read so one bad tick of a single call
    /// can't paint the banner. A lone failure is self-healing (the host's
    /// token provider refreshes in place; the next 20s tick covers a blip),
    /// so the banner only shows once the SAME read has failed twice in a row —
    /// but persistent failure MUST still surface: the swallow-everything
    /// approach was tried and reverted (2436be0) because it hid real breakage.
    /// User-initiated paths (mutations, timeline, transitions) stay immediate.
    private var pollFailureStreaks: [String: Int] = [:]

    /// One failed poll read: bump its streak; paint only from the 2nd
    /// consecutive failure of that read.
    private func reportPollFailure(_ key: String, _ error: Error) {
        let streak = (pollFailureStreaks[key] ?? 0) + 1
        pollFailureStreaks[key] = streak
        if streak >= 2 { lastError = describe(error) }
    }

    /// One good poll read: reset its streak, and clear the banner unless another
    /// read is still failing persistently (one healthy read mustn't hide another
    /// one's breakage).
    private func pollSucceeded(_ key: String) {
        pollFailureStreaks[key] = 0
        if pollFailureStreaks.values.allSatisfy({ $0 < 2 }) { lastError = nil }
    }

    /// The SwiftData container backing this sync's store. Exposed so pushed screens
    /// can attach it to their `@Query` environment.
    public var container: ModelContainer { store.container }

    public init(transport: any TraxTransport, store: TraxStore, currentUserID: UUID) {
        self.transport = transport
        self.store = store
        self.currentUserID = currentUserID
        publish()   // a cold start shows what the store already holds
    }

    /// Republish the snapshots from the store. Values are assigned only when
    /// they changed, so an idle poll re-renders nothing; `revision` moves when
    /// the store saved anything.
    func publish() {
        if store.changes != publishedChanges {
            publishedChanges = store.changes
            revision += 1
        }
        let inc = store.incomingSnapshots()
        if inc != incoming { incoming = inc }
        let places = store.placeSnapshots()
        if places != placeSnapshots { placeSnapshots = places }
    }

    public convenience init(config: TraxConfig, store: TraxStore) {
        self.init(transport: config.transport, store: store, currentUserID: config.currentUserID)
    }

    // MARK: - Reads

    /// Pull everything new since the persisted cursor, draining pages until the
    /// server reports no more (or the cursor stops advancing).
    public func refresh() async {
        // One refresh at a time. A caller arriving mid-refresh waits for it, plus
        // one more pass (its own request may postdate what the running one read).
        if let running = inflight {
            refreshAgain = true
            await running.value
            return
        }
        let task = Task { await self.runRefreshes() }
        inflight = task
        await task.value
        inflight = nil
    }

    private func runRefreshes() async {
        isLoading = true
        defer { isLoading = false }
        repeat {
            refreshAgain = false
            await refreshOnce()
        } while refreshAgain && !Task.isCancelled
    }

    private func refreshOnce() async {
        let gen = generation
        guard current(gen) else { return }
        var since = store.cursor()
        do {
            while true {
                let page = try await transport.feed(since: since > 0 ? since : nil, limit: nil)
                guard current(gen) else { return }   // stopped or wiped meanwhile: write nothing
                store.applyFeedPage(page)
                if let trs = page.transitions, !trs.isEmpty { mergeTransitions(trs) }
                guard page.hasMore, page.syncTs > since else { break }
                since = page.syncTs
            }
            publish()
            pollSucceeded("feed")
        } catch is CancellationError {
            // Benign — the next refresh covers it.
        } catch {
            if current(gen) { reportPollFailure("feed", error) }
        }
    }

    /// Refresh my outgoing shares (the "who I'm sharing with" list + stop controls).
    public func refreshOutgoing() async {
        let gen = generation
        guard current(gen) else { return }
        do {
            let fresh = try await transport.shares().outgoing
            guard current(gen) else { return }
            if fresh != outgoing { outgoing = fresh }
            pollSucceeded("outgoing")
        } catch is CancellationError {
        } catch {
            if current(gen) { reportPollFailure("outgoing", error) }
        }
    }

    /// The caller's own identity from the people directory (name + avatar).
    public func me() async throws -> TraxContact {
        try await transport.me()
    }

    /// Fetch the people directory (friends + my own entry) into the local store
    /// for labelling sharers and populating the share picker.
    public func loadContacts() async {
        let gen = generation
        guard current(gen) else { return }
        do {
            let contacts = try await transport.contacts()
            let me = try? await transport.me()
            guard current(gen) else { return }
            store.upsertContacts(contacts)
            if let me { store.upsertContact(me); store.save() }
            publish()
            pollSucceeded("contacts")
        } catch is CancellationError {
        } catch {
            if current(gen) { reportPollFailure("contacts", error) }
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

    /// When a fix was last posted SUCCESSFULLY (the throttle counts from here,
    /// so a failed post doesn't spend it).
    private var lastPostedAt: Date?
    /// The newest fix not yet delivered (latest wins; older unsent fixes are
    /// superseded, not queued).
    private var pendingTrack: TrackBody?
    private var trackInFlight = false
    /// The server's answer to the last delivered fix (its `shares` count says
    /// whether anyone is still receiving my location).
    private(set) var lastTrackAck: TrackAckDTO?

    /// The kit's tracking demand for the host, derived purely from share state —
    /// never leaks *who* is watching. The host decides how to satisfy it.
    /// (No active-watcher granularity yet, so any live share → `.continuous`.)
    public var trackingDemand: TraxTrackingDemand { outgoing.isEmpty ? .off : .continuous }

    /// Ingest one enriched fix from the host and post it to mvTrax — but ONLY while
    /// I'm sharing, throttled. This is the producer-collapse: the host owns the
    /// device + the cadence tier; the kit just gates on sharing + throttles uploads.
    /// A failed post keeps the fix pending: the next fix (or poll tick) sends the
    /// newest one.
    public func ingestFix(_ fix: TraxFix, minInterval: TimeInterval = 5) {
        guard !isWiped, !outgoing.isEmpty else { return }            // not sharing → nothing to post
        if let last = lastPostedAt, Date().timeIntervalSince(last) < minInterval { return }
        pendingTrack = TrackBody(
            lat: fix.lat, lng: fix.lng, accuracy: fix.horizontalAccuracy,
            altitude: fix.altitude, speed: fix.speed, heading: fix.course,
            motion: fix.motion, batteryLevel: fix.batteryLevel, batteryCharging: fix.batteryCharging,
            clientTs: Int64(fix.timestamp.timeIntervalSince1970 * 1000))
        flushPendingTrack()
    }

    /// Deliver the pending fix, if any and nothing is already in flight. Called
    /// by `ingestFix` and by the poll (so a fix whose post failed still goes out
    /// when no new fix arrives).
    func flushPendingTrack() {
        guard !trackInFlight, pendingTrack != nil, current(generation) else { return }
        trackInFlight = true
        let gen = generation
        Task {
            defer { self.trackInFlight = false }
            while let body = self.pendingTrack, self.current(gen) {
                self.pendingTrack = nil
                do {
                    let ack = try await self.transport.track(body)
                    guard self.current(gen) else { return }
                    self.lastPostedAt = Date()
                    self.lastTrackAck = ack
                } catch {
                    // Keep it for the next attempt unless a newer fix already
                    // replaced it, or retrying can't help.
                    if self.pendingTrack == nil, isRetryable(error), self.current(gen) {
                        self.pendingTrack = body
                    }
                    return
                }
            }
        }
    }

    // MARK: - Places (the user's own)

    /// Pull the user's places into the local store (drives the Places tab + the
    /// geofence monitor).
    public func loadPlaces() async {
        let gen = generation
        guard current(gen) else { return }
        do {
            let places = try await transport.places()
            guard current(gen) else { return }
            store.replacePlaces(places)
            publish()
            pollSucceeded("places")
        } catch is CancellationError {
        } catch {
            if current(gen) { reportPollFailure("places", error) }
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
            lastError = describe(error)
        }
    }

    /// Fold my own crossing into the live (observable) buffer + the durable store,
    /// resolving the place from my local set — so the owner sees their own arrival
    /// without waiting on (or ever receiving) a feed echo.
    private func recordOwnTransition(placeID: UUID, event: String) {
        guard !isWiped, let place = store.allPlaces().first(where: { $0.id == placeID }) else { return }
        let dto = TransitionDTO(
            id: UUID(), ownerId: currentUserID, placeId: placeID,
            placeName: place.name, placeEmoji: place.emoji, event: event,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000))
        store.upsertTransition(dto); store.save()
        publish()
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
        guard !trs.isEmpty, !isWiped else { return }
        if ownerID == currentUserID {
            for t in trs { store.upsertTransition(t) }   // server copies replace my local ones
            store.save()
            publish()
        }
        mergeTransitions(trs)
    }

    // MARK: - helpers

    /// Merge new transitions (newest first, dedup, cap 50). A copy of one of my
    /// own crossings (recorded locally the moment it happened, under a local id)
    /// replaces the local one when it comes back from the server under its own
    /// id: same place, same event, within `TransitionDTO.sameEventWindowMs`.
    private func mergeTransitions(_ incoming: [TransitionDTO]) {
        var merged = recentTransitions
        for t in incoming {
            if merged.contains(where: { $0.id == t.id }) { continue }
            if let i = merged.firstIndex(where: { $0.isSameEvent(as: t) }) {
                merged[i] = t
            } else {
                merged.append(t)
            }
        }
        recentTransitions = Array(merged.sorted { $0.createdAt > $1.createdAt }.prefix(50))
    }

    private func describe(_ error: Error) -> String {
        // Auth failures get a human string — these only reach the banner after
        // the debounce, i.e. when the condition is persistent, so the text
        // describes a state, not a blip. mvTrax now distinguishes expiry
        // ("token expired") from everything else at the wire.
        if case TraxTransportError.notAuthenticated = error { return "Not signed in" }
        if let te = error as? TraxError {
            if te.code == "unauthenticated" {
                return te.message == "token expired" ? "Session expired" : "Authentication failed"
            }
            return te.description
        }
        return String(describing: error)
    }
}
