import Foundation
import SwiftData

/// TraxKit's persistence façade and the **single local owner** of Trax data.
/// **Main-actor confined** — the main `ModelContext` is the only safe place to
/// touch SwiftData; network I/O is `async` and hops off-main inside the transport.
///
/// Identity-scoped: the on-disk file is `Trax-{userID}.store`, so a different account
/// opens a DIFFERENT file — cross-account bleed is impossible by construction (it's
/// never a matter of remembering to wipe). App-Group placement is host-provided
/// (a host app → its app group; TraxLab/dev → the app's default container). Open is
/// non-fatal: a corrupt/locked store recreates, then falls back to in-memory rather
/// than bricking launch.
@MainActor
public final class TraxStore {
    public let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// Per-user store. `directory`, when given, is the folder it lives in (the
    /// host's choice, e.g. one kept out of device backups). Otherwise `appGroup`
    /// is the host's group identifier (e.g. "group.com.example.app"), and nil
    /// uses the app's own container.
    public init(userID: UUID, appGroup: String? = nil, directory: URL? = nil) {
        let schema = Schema(versionedSchema: TraxSchemaV1.self)
        let name = "Trax-\(userID.uuidString)"
        let config: ModelConfiguration
        if let directory {
            config = ModelConfiguration(name, schema: schema, url: directory.appending(path: "\(name).store"))
        } else {
            let group: ModelConfiguration.GroupContainer = appGroup.map { .identifier($0) } ?? .none
            config = ModelConfiguration(name, schema: schema, groupContainer: group)
        }
        self.container = Self.open(schema: schema, configuration: config)
    }

    /// In-memory store (tests / previews / TraxLab without a signed-in identity).
    public init(inMemory: Bool) {
        let schema = Schema(versionedSchema: TraxSchemaV1.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        self.container = (try? ModelContainer(for: schema, migrationPlan: TraxMigrationPlan.self, configurations: config))
            ?? Self.inMemoryFallback(schema)
    }

    private static func open(schema: Schema, configuration config: ModelConfiguration) -> ModelContainer {
        // First launch: the store's parent dir (Application Support, or the host's
        // folder) may not exist yet,
        // which makes the initial open fail-then-recover noisily. Pre-create it.
        try? FileManager.default.createDirectory(at: config.url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            return try ModelContainer(for: schema, migrationPlan: TraxMigrationPlan.self, configurations: config)
        } catch {
            // Recreate-on-failure: drop the bad file + retry once, then in-memory.
            try? FileManager.default.removeItem(at: config.url)
            if let c = try? ModelContainer(for: schema, migrationPlan: TraxMigrationPlan.self, configurations: config) {
                return c
            }
            return inMemoryFallback(schema)   // never brick launch
        }
    }

    private static func inMemoryFallback(_ schema: Schema) -> ModelContainer {
        let mem = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: mem)  // effectively never throws
    }

    // MARK: - Cursor

    public func cursor() -> Int64 {
        let fetch = FetchDescriptor<SyncCursorEntity>(predicate: #Predicate { $0.key == "feed" })
        return (try? context.fetch(fetch).first?.syncTs) ?? 0
    }

    /// The feed's revision cursor (nil before the first revision-mode sync).
    public func revCursor() -> Int64? {
        let fetch = FetchDescriptor<SyncCursorEntity>(predicate: #Predicate { $0.key == "rev" })
        return try? context.fetch(fetch).first?.syncTs
    }

    /// Keep the server's revision as given: after a reload it's the server's
    /// word on where this client stands, not something to max() against.
    public func setRevCursor(_ rev: Int64) {
        let fetch = FetchDescriptor<SyncCursorEntity>(predicate: #Predicate { $0.key == "rev" })
        if let existing = try? context.fetch(fetch).first {
            existing.syncTs = rev
        } else {
            context.insert(SyncCursorEntity(key: "rev", syncTs: rev))
        }
    }

    public func setCursor(_ ts: Int64) {
        let fetch = FetchDescriptor<SyncCursorEntity>(predicate: #Predicate { $0.key == "feed" })
        if let existing = try? context.fetch(fetch).first {
            existing.syncTs = max(existing.syncTs, ts)   // monotonic — a regressing server can't rewind us
        } else {
            context.insert(SyncCursorEntity(syncTs: ts))
        }
    }

    // MARK: - Feed delta application

    /// Apply one feed page: drop stopped shares, upsert active ones, fold in
    /// transitions, advance the cursor. Stopped ids first so a stop+restart in one
    /// page nets to "present".
    public func applyFeedPage(_ page: FeedDTO) {
        if page.reload == true { deleteAllShares() }
        for id in page.stoppedIds ?? [] { deleteShare(id: id) }
        for dto in page.shares { upsertShare(dto) }
        for t in page.transitions ?? [] { upsertTransition(t) }
        setCursor(page.syncTs)
        if page.isRevisioned, let rev = page.rev, rev > 0 { setRevCursor(rev) }
        save()
    }

    public func upsertShare(_ dto: ShareDTO) {
        let id = dto.id
        let fetch = FetchDescriptor<ShareEntity>(predicate: #Predicate { $0.id == id })
        let e = (try? context.fetch(fetch).first) ?? {
            let new = ShareEntity(id: dto.id, ownerId: dto.ownerId, mode: dto.mode,
                                  retention: dto.retention, startedAt: dto.startedAt,
                                  expiresAt: dto.expiresAt, updatedAt: dto.location?.recordedAt ?? dto.startedAt)
            context.insert(new)
            return new
        }()
        e.ownerId = dto.ownerId
        e.mode = dto.mode
        e.retention = dto.retention
        e.precision = dto.precision
        e.startedAt = dto.startedAt
        e.expiresAt = dto.expiresAt
        e.fuzzRadiusM = dto.fuzzRadiusM
        e.placeName = dto.placeName
        e.placeEmoji = dto.placeEmoji
        e.atPlace = dto.atPlace ?? false
        if let loc = dto.location {
            e.lat = loc.lat; e.lng = loc.lng; e.accuracy = loc.accuracy; e.altitude = loc.altitude
            e.speed = loc.speed; e.heading = loc.heading; e.motion = loc.motion; e.network = loc.network
            e.batteryLevel = loc.batteryLevel; e.batteryCharging = loc.batteryCharging
            e.locRecordedAt = loc.recordedAt
            e.updatedAt = loc.recordedAt
        } else {
            e.lat = nil; e.lng = nil; e.locRecordedAt = nil
        }
    }

    /// A reload: every share held goes; the page that follows is the full set.
    func deleteAllShares() {
        try? context.delete(model: ShareEntity.self)
    }

    /// Drop shares whose expiry has passed (a server that doesn't tombstone
    /// expiry never removes them). Returns whether any went.
    @discardableResult
    func deleteExpiredShares(now: Date = Date()) -> Bool {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let fetch = FetchDescriptor<ShareEntity>(predicate: #Predicate { $0.expiresAt != nil })
        let expired = ((try? context.fetch(fetch)) ?? []).filter { $0.expiresAt! <= nowMs }
        for e in expired { context.delete(e) }
        return !expired.isEmpty
    }

    public func deleteShare(id: UUID) {
        let fetch = FetchDescriptor<ShareEntity>(predicate: #Predicate { $0.id == id })
        if let e = try? context.fetch(fetch).first { context.delete(e) }
    }

    /// The active share where `ownerID` is sharing with me — newest non-expired row.
    /// Deterministic (sorted by `updatedAt`, expiry-filtered) so the header can't flicker
    /// between rows or show a stale/expired fix.
    public func incomingShare(ownerID: UUID) -> ShareEntity? {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetch = FetchDescriptor<ShareEntity>(
            predicate: #Predicate { $0.ownerId == ownerID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? context.fetch(fetch))?.first { $0.expiresAt == nil || $0.expiresAt! > now }
    }

    // MARK: - Directory

    public func upsertContacts(_ contacts: [TraxContact]) {
        for c in contacts { upsertContact(c) }
        save()
    }

    public func upsertContact(_ c: TraxContact) {
        let id = c.id
        let fetch = FetchDescriptor<ContactEntity>(predicate: #Predicate { $0.id == id })
        if let e = try? context.fetch(fetch).first {
            e.name = c.name; e.avatar = c.avatar
        } else {
            context.insert(ContactEntity(id: c.id, name: c.name, avatar: c.avatar))
        }
    }

    // MARK: - Places (the user's own)

    /// Replace the local place set with the server's list (source of truth).
    public func replacePlaces(_ places: [PlaceDTO]) {
        let existing = (try? context.fetch(FetchDescriptor<PlaceEntity>())) ?? []
        for e in existing { context.delete(e) }
        for p in places {
            context.insert(PlaceEntity(id: p.id, ownerId: p.ownerId, name: p.name, type: p.type,
                                       lat: p.lat, lng: p.lng, radiusM: p.radiusM, emoji: p.emoji,
                                       address: p.address, sharedWith: p.sharedWith ?? [], updatedAt: p.updatedAt))
        }
        save()
    }

    public func allPlaces() -> [PlaceEntity] {
        (try? context.fetch(FetchDescriptor<PlaceEntity>())) ?? []
    }

    // MARK: - Transitions (durable, first-class)

    public func upsertTransition(_ dto: TransitionDTO) {
        let id = dto.id
        let fetch = FetchDescriptor<TransitionEntity>(predicate: #Predicate { $0.id == id })
        if (try? context.fetch(fetch).first) != nil { return }
        // The server's copy of a crossing this device recorded under a local id:
        // adopt the server's id + time. Only a local record is ever rewritten.
        if !dto.id.isLocalTransitionID {
            let owner = dto.ownerId, place = dto.placeId, event = dto.event
            let lo = dto.createdAt - TransitionDTO.sameEventWindowMs, hi = dto.createdAt + TransitionDTO.sameEventWindowMs
            let candidates = FetchDescriptor<TransitionEntity>(predicate: #Predicate {
                $0.ownerId == owner && $0.placeId == place && $0.event == event && $0.createdAt >= lo && $0.createdAt <= hi
            })
            if let local = ((try? context.fetch(candidates)) ?? []).first(where: { $0.id.isLocalTransitionID }) {
                local.id = dto.id
                local.createdAt = dto.createdAt
                return
            }
        }
        context.insert(TransitionEntity(id: dto.id, ownerId: dto.ownerId, placeId: dto.placeId,
                                        placeName: dto.placeName, placeEmoji: dto.placeEmoji,
                                        event: dto.event, createdAt: dto.createdAt))
    }

    /// An owner's enter/leave events, newest first — what the chat bridge projects.
    public func transitions(ownerID: UUID, limit: Int? = nil) -> [TransitionEntity] {
        var fetch = FetchDescriptor<TransitionEntity>(
            predicate: #Predicate { $0.ownerId == ownerID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if let limit { fetch.fetchLimit = limit }
        return (try? context.fetch(fetch)) ?? []
    }

    /// Drop an owner's enter/leave events from before `cutoffMs` (nil = all).
    func deleteTransitions(ownerID: UUID, before cutoffMs: Int64?) {
        let cut = cutoffMs ?? .max
        try? context.delete(model: TransitionEntity.self,
                            where: #Predicate { $0.ownerId == ownerID && $0.createdAt < cut })
    }

    public func save() {
        guard context.hasChanges else { return }
        try? context.save()
        changes += 1
    }

    /// Bumped on every save that changed something (and by a wipe): the sync
    /// layer republishes its snapshots when this moves.
    public private(set) var changes = 0

    // MARK: - Snapshots (values for the sync layer to publish)

    /// Each sharer's current share pointed at me: the newest unexpired row per
    /// owner (same rule as `incomingShare(ownerID:)`).
    func incomingSnapshots(now: Date = Date()) -> [UUID: IncomingShareSnapshot] {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let fetch = FetchDescriptor<ShareEntity>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        var out: [UUID: IncomingShareSnapshot] = [:]
        for e in (try? context.fetch(fetch)) ?? [] where out[e.ownerId] == nil {
            if let exp = e.expiresAt, exp <= nowMs { continue }
            out[e.ownerId] = IncomingShareSnapshot(e)
        }
        return out
    }

    /// Everyone in the people directory (friends and me), by name.
    func contactSnapshots() -> [TraxContact] {
        let fetch = FetchDescriptor<ContactEntity>(sortBy: [SortDescriptor(\.name), SortDescriptor(\.id)])
        return ((try? context.fetch(fetch)) ?? []).map { TraxContact(id: $0.id, name: $0.name, avatar: $0.avatar) }
    }

    /// Every place visible to me, by name (stable order).
    func placeSnapshots() -> [PlaceSnapshot] {
        allPlaces().map(PlaceSnapshot.init)
            .sorted { ($0.name.lowercased(), $0.id.uuidString) < ($1.name.lowercased(), $1.id.uuidString) }
    }

    // MARK: - Wipe (sign-out)

    /// Delete every persisted entity through the live context — the SwiftData-
    /// sanctioned wipe (mirrors the host app's `TrackerDataCleanup.clearAll`). This
    /// is deliberately a row-delete, NOT a file delete: unlinking the `.store` while
    /// the container is open is a SQLite integrity violation ("vnode unlinked while
    /// in use"). Leaves an empty, valid store for the next session. Enumerated by
    /// type because SwiftData has no "delete every model" API — keep this list in
    /// sync with `TraxSchemaV1.models`.
    public func wipeAll() {
        try? context.delete(model: ShareEntity.self)
        try? context.delete(model: ContactEntity.self)
        try? context.delete(model: PlaceEntity.self)
        try? context.delete(model: TransitionEntity.self)
        try? context.delete(model: SyncCursorEntity.self)
        save()
        changes += 1
    }
}
