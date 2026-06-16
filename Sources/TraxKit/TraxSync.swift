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

    private let transport: any TraxTransport
    private let store: TraxStore
    private var isRefreshing = false

    /// The SwiftData container backing this sync's store. Exposed so pushed screens
    /// can attach it to their `@Query` environment.
    public var container: ModelContainer { store.container }

    public init(transport: any TraxTransport, store: TraxStore) {
        self.transport = transport
        self.store = store
    }

    public convenience init(config: TraxConfig, store: TraxStore) {
        self.init(transport: config.transport, store: store)
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

    /// Producer hook: ingest one fix. The full CoreLocation producer (acquire +
    /// cadence + region transitions) lands on top of this next.
    @discardableResult
    public func track(_ body: TrackBody) async throws -> TrackAckDTO {
        try await transport.track(body)
    }

    // MARK: - helpers

    private func describe(_ error: Error) -> String {
        if let te = error as? TraxError { return te.description }
        return String(describing: error)
    }
}
