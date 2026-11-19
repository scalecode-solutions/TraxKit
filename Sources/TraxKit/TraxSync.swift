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
    /// The same shares as a list, newest first (what the hub lists and pins).
    private(set) var incomingList: [IncomingShareSnapshot] = []
    /// Places visible to me, published as values.
    private(set) var placeSnapshots: [PlaceSnapshot] = []
    /// The people directory (friends and me), by name, as values.
    private(set) var contacts: [TraxContact] = []
    /// The same directory by id, built once per change (every row looks names up).
    private(set) var contactsByID: [UUID: TraxContact] = [:]
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
        lastDelivered = nil
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
        // Shares are re-read every time (expiry is a function of the clock);
        // places and people only when the store saved something.
        let storeMoved = store.changes != publishedChanges
        if storeMoved {
            publishedChanges = store.changes
            revision += 1
        }
        let inc = store.incomingSnapshots()
        if inc != incoming {
            incoming = inc
            incomingList = inc.values.sorted { ($0.updatedAt, $0.shareID.uuidString) > ($1.updatedAt, $1.shareID.uuidString) }
        }
        guard storeMoved else { return }
        let places = store.placeSnapshots()
        if places != placeSnapshots { placeSnapshots = places }
        let people = store.contactSnapshots()
        if people != contacts {
            contacts = people
            contactsByID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
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
    }

    /// How far each feed request reaches back before the last sync time.
    static let sinceOverlapMs: Int64 = 120_000
    /// A runaway guard: no single refresh drains more pages than this.
    static let maxFeedPages = 50

    private func runRefreshes() async {
        isLoading = true
        repeat {
            refreshAgain = false
            await refreshOnce()
        } while refreshAgain && !Task.isCancelled
        // Cleared here, in the same main-actor step that decides there's no
        // further pass: a caller can't find a finished task still installed.
        refreshAgain = false
        inflight = nil
        isLoading = false
    }

    private func refreshOnce() async {
        let gen = generation
        guard current(gen) else { return }
        // Transitions (and the whole feed, from a server in timestamp mode)
        // follow `since`. It overlaps the last sync by a margin so a write that
        // committed late isn't skipped; transitions dedupe by id and shares upsert.
        let cursor = store.cursor()
        var since: Int64? = cursor > 0 ? max(0, cursor - Self.sinceOverlapMs) : nil
        let held = store.revCursor()
        var rev = held ?? 0
        var loadFrom: Int64?
        var applied = false
        var firstPage = true
        // Publish whatever was applied, even if a later page fails.
        defer { if applied && current(gen) { publish() } }
        do {
            for _ in 0..<Self.maxFeedPages {
                let page = try await transport.feed(since: since, rev: rev, loadFrom: loadFrom, limit: nil)
                guard current(gen) else { return }   // stopped or wiped meanwhile: write nothing
                // The first revision-mode answer to a store synced by timestamp
                // (an upgrade): a full load can't name shares the server has
                // already purged, so it replaces what's held, like a reload.
                if firstPage, held == nil, page.isRevisioned { store.deleteAllShares() }
                firstPage = false
                store.applyFeedPage(page)
                applied = true
                if let trs = page.transitions, !trs.isEmpty { mergeTransitions(trs) }
                guard page.hasMore else { break }
                if page.isRevisioned {
                    // Revision order: keep `since` (transitions came on the first
                    // page), follow the server's cursor, stop if it doesn't move.
                    let next = page.rev ?? rev
                    guard next != rev || page.loadFrom != loadFrom else { break }
                    rev = next; loadFrom = page.loadFrom
                } else {
                    // Timestamp mode (an older server): page by sync time.
                    guard page.syncTs > (since ?? 0) else { break }
                    since = page.syncTs
                }
            }
            if store.deleteExpiredShares() { store.save(); applied = true }
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
            lastOutgoingAt = Date()
            if fresh.isEmpty { pendingTrack = nil }   // nothing to deliver a fix to any more
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

    /// The last fix the server accepted: what `UploadPolicy` compares a new fix
    /// with (a failed post doesn't count, so it doesn't hold the next one back).
    private(set) var lastDelivered: TraxFix?
    /// The newest fix not yet delivered, with the body it goes out as (latest
    /// wins; older unsent fixes are superseded, not queued).
    private var pendingTrack: (fix: TraxFix, body: TrackBody)?
    private var trackInFlight = false
    /// The server's answer to the last delivered fix (its `shares` count says
    /// whether anyone is still receiving my location).
    private(set) var lastTrackAck: TrackAckDTO?
    private var lastAckAt: Date?
    private var lastOutgoingAt: Date?

    /// Whether I'm live-sharing now (ShareLivenessPolicy): an unexpired outgoing
    /// share, and the last fix's ack didn't say my shares are gone.
    public var isSharing: Bool {
        ShareLivenessPolicy.shouldPost(
            outgoingExpiries: outgoing.map(\.expiresAt),
            activeSharesInLastAck: lastTrackAck?.shares,
            ackNewerThanOutgoing: (lastAckAt ?? .distantPast) > (lastOutgoingAt ?? .distantPast),
            now: Date())
    }
    /// Send each fix's own time as `recordedAt`, so the server files it under
    /// when it was taken rather than when it arrived (a retried fix arrives
    /// late). Turned off for the session if the server refuses the device's
    /// clock (more than its allowed skew ahead): fixes then go out stamped by
    /// the server, as before, instead of all being refused.
    private var sendsRecordedAt = true

    /// The precisions of my live shares (empty when I'm not sharing). A
    /// precision this kit doesn't know reads as approx, the quietest that shares.
    var livePrecisions: Set<TraxPrecision> {
        guard isSharing else { return [] }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return Set(outgoing.filter { ($0.expiresAt ?? .max) > nowMs }
            .map { TraxPrecision(rawValue: $0.precision) ?? .approx })
    }

    /// The kit's tracking demand for the host, derived purely from share state —
    /// never leaks *who* is watching. Assumes foreground + permission; the
    /// engine asks TrackingDemandPolicy with the real auth and app state.
    public var trackingDemand: TraxTrackingDemand {
        TrackingDemandPolicy.demand(precisions: livePrecisions, auth: .whenInUse, foreground: true)
    }

    /// Ingest one enriched fix from the host and post it to mvTrax — but ONLY while
    /// I'm sharing, and only when it says something new (`UploadPolicy`: moved,
    /// motion changed, or the heartbeat is due). This is the producer-collapse:
    /// the host owns the device + the cadence tier; the kit gates on sharing and
    /// decides what's worth uploading. A failed post keeps the fix pending: the
    /// next fix (or poll tick) sends the newest one.
    public func ingestFix(_ fix: TraxFix) {
        guard !isWiped, isSharing else { return }                    // not sharing → nothing to post
        guard UploadPolicy.decide(last: lastDelivered, new: fix, now: Date()) == .post else { return }
        pendingTrack = (fix, TrackBody(
            lat: fix.lat, lng: fix.lng, accuracy: fix.horizontalAccuracy,
            altitude: fix.altitude, speed: fix.speed, heading: fix.course,
            motion: fix.motion, batteryLevel: fix.batteryLevel, batteryCharging: fix.batteryCharging,
            clientTs: Int64(fix.timestamp.timeIntervalSince1970 * 1000),
            recordedAt: sendsRecordedAt ? Int64(fix.timestamp.timeIntervalSince1970 * 1000) : nil))
        flushPendingTrack()
    }

    /// Deliver the pending fix, if any and nothing is already in flight. Called
    /// by `ingestFix` and by the poll (so a fix whose post failed still goes out
    /// when no new fix arrives).
    func flushPendingTrack() {
        guard isSharing else { pendingTrack = nil; return }           // stopped sharing: never post
        guard !trackInFlight, pendingTrack != nil, current(generation) else { return }
        trackInFlight = true
        let gen = generation
        Task {
            defer { self.trackInFlight = false }
            while let item = self.pendingTrack, self.current(gen), self.isSharing {
                self.pendingTrack = nil
                let body = item.body
                do {
                    let ack = try await self.transport.track(body)
                    guard self.current(gen) else { return }
                    self.lastDelivered = item.fix
                    self.lastTrackAck = ack
                    self.lastAckAt = Date()
                } catch {
                    guard self.current(gen) else { return }
                    // The server refused the fix's time (the device clock is
                    // off): stop sending it and resend this fix without it.
                    if body.recordedAt != nil, Self.refusesRecordedAt(error) {
                        self.sendsRecordedAt = false
                        if self.pendingTrack == nil {
                            var unstamped = body
                            unstamped.recordedAt = nil
                            self.pendingTrack = (item.fix, unstamped)
                        } else {
                            self.pendingTrack?.body.recordedAt = nil
                        }
                        continue
                    }
                    // Keep it for the next attempt unless a newer fix already
                    // replaced it, or retrying can't help.
                    if self.pendingTrack == nil, isRetryable(error) {
                        self.pendingTrack = item
                    }
                    return
                }
            }
        }
    }

    /// The server refusing a fix stamped ahead of its clock (mvTrax's Track:
    /// "recorded_at is in the future"). Too old is a different refusal: that
    /// fix is dropped, not restamped.
    static func refusesRecordedAt(_ error: Error) -> Bool {
        guard let e = error as? TraxError else { return false }
        return e.code == "invalid_argument" && e.message.contains("recorded_at is in the future")
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
            id: .localTransitionID(), ownerId: currentUserID, placeId: placeID,
            placeName: place.name, placeEmoji: place.emoji, event: event,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000))
        store.upsertTransition(dto); store.save()
        publish()
        mergeTransitions([dto])
    }

    // MARK: - Clear history

    /// Delete my history before `before` (nil = all) on the server: points and
    /// what's derived from them (visits, trips, transitions). Then drop my own
    /// crossings from the local store and the live buffer, so the "You arrived"
    /// rows go with them. Returns the number of points the server deleted.
    func clearMyHistory(before: Date?) async throws -> Int {
        let cutoffMs = before.map { Int64($0.timeIntervalSince1970 * 1000) }
        let gen = generation
        let n = try await transport.clearHistory(before: cutoffMs)
        guard current(gen) else { return Int(n.count) }
        store.deleteTransitions(ownerID: currentUserID, before: cutoffMs)
        store.save()
        recentTransitions.removeAll { $0.ownerId == currentUserID && $0.createdAt < (cutoffMs ?? .max) }
        publish()
        return Int(n.count)
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
            // Bounded to the day on the server, so a past day isn't crowded out
            // by everything since it. The filter stays for a server that
            // ignores `before`.
            let trips = try await transport.tripsFor(ownerId: ownerID, since: sinceMs, before: endMs, limit: 1000)
                .filter { $0.startTs < endMs }
            let visits = try await transport.visitsFor(ownerId: ownerID, since: sinceMs, before: endMs, limit: 1000)
                .filter { $0.startTs < endMs }
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
        await fetchTransitions(ownerID: ownerID, since: since, limit: limit).list
    }

    /// The read plus the generation it started under, so a writer can drop it.
    private func fetchTransitions(ownerID: UUID, since: Int64?, limit: Int?) async -> (list: [TransitionDTO], gen: Int) {
        let gen = generation
        do {
            let trs = try await transport.transitionsFor(ownerId: ownerID, since: since, limit: limit)
            if current(gen) { lastError = nil }
            return (trs, gen)
        } catch is CancellationError {
            return ([], gen)
        } catch {
            if current(gen) { lastError = describe(error) }
            return ([], gen)
        }
    }

    /// Fetch an owner's durable enter/leave history and fold it into the live
    /// `recentTransitions` buffer — so a chat thread's backfill of past arrivals
    /// rides the SAME @Observable path as the live feed, instead of a second source
    /// the host has to merge separately (which won't reliably refresh the UI).
    public func backfillTransitions(ownerID: UUID, limit: Int? = nil) async {
        let (trs, gen) = await fetchTransitions(ownerID: ownerID, since: nil, limit: limit)
        guard !trs.isEmpty, current(gen) else { return }
        if ownerID == currentUserID {
            for t in trs { store.upsertTransition(t) }   // server copies replace my local ones
            store.save()
            publish()
        }
        mergeTransitions(trs)
    }

    // MARK: - helpers

    /// Merge new transitions (newest first, dedup by id, cap 50). The server's
    /// copy of one of my own crossings replaces the local record of it (see
    /// `TransitionDTO.isLocalTwin`); server records never replace each other.
    private func mergeTransitions(_ incoming: [TransitionDTO]) {
        var merged = recentTransitions
        for t in incoming {
            if merged.contains(where: { $0.id == t.id }) { continue }
            if let i = merged.firstIndex(where: { $0.isLocalTwin(of: t) }) {
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
