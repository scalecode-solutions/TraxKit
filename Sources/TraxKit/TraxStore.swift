import Foundation
import SwiftData

/// TraxKit's persistence façade and the **single local owner** of Trax data.
/// **Main-actor confined** — the main `ModelContext` is the only safe place to
/// touch SwiftData; network I/O is `async` and hops off-main inside the transport.
///
/// Identity-scoped: the on-disk file is `Trax-{userID}.store`, so a different account
/// opens a DIFFERENT file — cross-account bleed is impossible by construction (it's
/// never a matter of remembering to wipe). App-Group placement is host-provided
/// (Clingy → its group; TraxLab/dev → the app's default container). Open is
/// non-fatal: a corrupt/locked store recreates, then falls back to in-memory rather
/// than bricking launch.
@MainActor
public final class TraxStore {
    public let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// Per-user, optionally App-Group-scoped store. `appGroup` is the host's group
    /// identifier (e.g. "group.app.mvchat.Clingy3"); nil uses the app's own container.
    public init(userID: UUID, appGroup: String? = nil) {
        let schema = Schema(versionedSchema: TraxSchemaV1.self)
        let group: ModelConfiguration.GroupContainer = appGroup.map { .identifier($0) } ?? .none
        let config = ModelConfiguration("Trax-\(userID.uuidString)", schema: schema, groupContainer: group)
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
        // First launch: the store's parent dir (Application Support) may not exist yet,
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
        for id in page.stoppedIds ?? [] { deleteShare(id: id) }
        for dto in page.shares { upsertShare(dto) }
        for t in page.transitions ?? [] { upsertTransition(t) }
        setCursor(page.syncTs)
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
        if (try? context.fetch(fetch).first) == nil {
            context.insert(TransitionEntity(id: dto.id, ownerId: dto.ownerId, placeId: dto.placeId,
                                            placeName: dto.placeName, placeEmoji: dto.placeEmoji,
                                            event: dto.event, createdAt: dto.createdAt))
        }
    }

    /// An owner's enter/leave events, newest first — what the chat bridge projects.
    public func transitions(ownerID: UUID, limit: Int? = nil) -> [TransitionEntity] {
        var fetch = FetchDescriptor<TransitionEntity>(
            predicate: #Predicate { $0.ownerId == ownerID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if let limit { fetch.fetchLimit = limit }
        return (try? context.fetch(fetch)) ?? []
    }

    public func save() {
        guard context.hasChanges else { return }
        try? context.save()
    }
}
