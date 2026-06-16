import Foundation
import SwiftData

/// TraxKit's persistence façade. **Main-actor confined** — the main `ModelContext`
/// is the only safe place to touch SwiftData (the lesson PulseKit/ClingySyncKit
/// learned). Network I/O is `async` and hops off-main inside the transport;
/// everything here stays on the main actor.
@MainActor
public final class TraxStore {
    public let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// On-disk store (the app path).
    public init() {
        let schema = Schema([ShareEntity.self, ContactEntity.self, SyncCursorEntity.self])
        let config = ModelConfiguration("TraxKit", schema: schema)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("TraxKit: failed to open store: \(error)")
        }
    }

    /// In-memory store (tests / previews / lab).
    public init(inMemory: Bool) {
        let schema = Schema([ShareEntity.self, ContactEntity.self, SyncCursorEntity.self])
        let config = ModelConfiguration("TraxKit", schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("TraxKit: failed to open in-memory store: \(error)")
        }
    }

    // MARK: - Cursor

    public func cursor() -> Int64 {
        let fetch = FetchDescriptor<SyncCursorEntity>(predicate: #Predicate { $0.key == "feed" })
        return (try? context.fetch(fetch).first?.syncTs) ?? 0
    }

    public func setCursor(_ ts: Int64) {
        let fetch = FetchDescriptor<SyncCursorEntity>(predicate: #Predicate { $0.key == "feed" })
        if let existing = try? context.fetch(fetch).first {
            existing.syncTs = ts
        } else {
            context.insert(SyncCursorEntity(syncTs: ts))
        }
    }

    // MARK: - Feed delta application

    /// Apply one feed page: drop stopped shares, upsert active ones, advance the
    /// cursor. Stopped ids are applied BEFORE upserts so a stop+restart in one
    /// page nets to "present".
    public func applyFeedPage(_ page: FeedDTO) {
        for id in page.stoppedIds ?? [] { deleteShare(id: id) }
        for dto in page.shares { upsertShare(dto) }
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
        e.startedAt = dto.startedAt
        e.expiresAt = dto.expiresAt
        if let loc = dto.location {
            e.lat = loc.lat; e.lng = loc.lng; e.accuracy = loc.accuracy; e.altitude = loc.altitude
            e.speed = loc.speed; e.heading = loc.heading; e.motion = loc.motion; e.network = loc.network
            e.batteryLevel = loc.batteryLevel; e.batteryCharging = loc.batteryCharging
            e.locRecordedAt = loc.recordedAt
            e.updatedAt = loc.recordedAt
        }
    }

    public func deleteShare(id: UUID) {
        let fetch = FetchDescriptor<ShareEntity>(predicate: #Predicate { $0.id == id })
        if let e = try? context.fetch(fetch).first { context.delete(e) }
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

    public func save() {
        guard context.hasChanges else { return }
        try? context.save()
    }
}
