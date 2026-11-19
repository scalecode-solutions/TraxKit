import Foundation
import SwiftData
import Testing
@testable import TraxKit

/// The feed in revision mode (and its fallback to timestamp mode for a server
/// that doesn't know `rev`).
@MainActor
@Suite struct RevSyncTests {
    let me = UUID(), alice = UUID(), bob = UUID()

    func rig() -> (FakeTraxTransport, TraxSync, TraxStore) {
        let t = FakeTraxTransport()
        let store = TraxStore(inMemory: true)
        return (t, TraxSync(transport: t, store: store, currentUserID: me), store)
    }

    /// Every share row held, expired or not (what a hub reading the store sees).
    func heldShareIDs(_ store: TraxStore) -> Set<UUID> {
        Set(((try? store.container.mainContext.fetch(FetchDescriptor<ShareEntity>())) ?? []).map(\.id))
    }

    func page(_ shares: [ShareDTO], stopped: [UUID] = [], syncTs: Int64 = Fixtures.nowMs(),
              hasMore: Bool = false, rev: Int64, reload: Bool = false, loadFrom: Int64? = nil) -> FeedDTO {
        FeedDTO(shares: shares, syncTs: syncTs, hasMore: hasMore, stoppedIds: stopped,
                rev: rev, reload: reload, loadFrom: loadFrom)
    }

    /// First sync asks from revision 0 with no `since`; the next asks from the
    /// kept revision, and `since` (for transitions) overlaps the last sync time.
    @Test func keepsTheRevisionAndOverlapsSince() async {
        let (t, sync, _) = rig()
        await t.queueFeed(page([Fixtures.share(owner: alice, viewer: me, lat: 1, lng: 1)], syncTs: 1_000_000, rev: 7))
        await sync.refresh()
        await sync.refresh()
        let r = await t.feedRequests
        #expect(r.count == 2)
        #expect(r[0].rev == 0 && r[0].since == nil && r[0].loadFrom == nil)
        #expect(r[1].rev == 7)
        #expect(r[1].since == 1_000_000 - TraxSync.sinceOverlapMs)
    }

    /// Paging: each next request echoes the page's revision and load_from with
    /// the same `since`; the final page's revision is the one kept.
    @Test func pagesFollowTheServersCursor() async {
        let (t, sync, store) = rig()
        await t.queueFeed(page([Fixtures.share(owner: alice, viewer: me)], hasMore: true, rev: 5, loadFrom: 3))
        await t.queueFeed(page([Fixtures.share(owner: bob, viewer: me)], rev: 9))
        await sync.refresh()
        let r = await t.feedRequests
        #expect(r.count == 2)
        #expect(r[1].rev == 5 && r[1].loadFrom == 3 && r[1].since == r[0].since)
        #expect(store.revCursor() == 9)
        #expect(sync.incoming.count == 2)
    }

    /// A reload drops every share held: what isn't in the reload is gone.
    @Test func reloadReplacesTheHeldSet() async {
        let (t, sync, store) = rig()
        let old = Fixtures.share(owner: alice, viewer: me, lat: 1, lng: 1)
        await t.queueFeed(page([old], rev: 4))
        await sync.refresh()
        #expect(heldShareIDs(store) == [old.id])

        let fresh = Fixtures.share(owner: bob, viewer: me, lat: 2, lng: 2)
        await t.queueFeed(page([fresh], rev: 40, reload: true))
        await sync.refresh()
        #expect(heldShareIDs(store) == [fresh.id])
        #expect(sync.incoming[alice] == nil)
        #expect(store.revCursor() == 40)
    }

    /// An expiry arrives as a removal like any stop.
    @Test func expiryTombstoneRemovesTheShare() async {
        let (t, sync, store) = rig()
        let s = Fixtures.share(owner: alice, viewer: me, lat: 1, lng: 1)
        await t.queueFeed(page([s], rev: 2))
        await sync.refresh()
        await t.queueFeed(page([], stopped: [s.id], rev: 3))
        await sync.refresh()
        #expect(heldShareIDs(store).isEmpty)
        #expect(sync.incoming[alice] == nil)
    }

    /// A server that never tombstones expiry: the expired row still goes, so a
    /// hub reading the store doesn't show it forever.
    @Test func expiredSharesAreDroppedLocally() async {
        let (t, sync, store) = rig()
        let live = Fixtures.share(owner: alice, viewer: me, lat: 1, lng: 1)
        let ended = Fixtures.share(owner: bob, viewer: me, lat: 2, lng: 2, expiresAt: Fixtures.nowMs(-60))
        await t.queueFeed(Fixtures.page([live, ended]))
        await sync.refresh()
        #expect(heldShareIDs(store) == [live.id])
    }

    /// An older server ignores `rev` and answers with rev 0: the timestamp path
    /// applies (paging by sync time) and no revision is kept.
    @Test func olderServerFallsBackToTimestamps() async {
        let (t, sync, store) = rig()
        await t.queueFeed(Fixtures.page([Fixtures.share(owner: alice, viewer: me)], syncTs: 500, hasMore: true))
        await t.queueFeed(Fixtures.page([Fixtures.share(owner: bob, viewer: me)], syncTs: 600))
        await sync.refresh()
        let r = await t.feedRequests
        #expect(r.count == 2)
        #expect(r[1].since == 500 && r[1].loadFrom == nil)
        #expect(store.revCursor() == nil)
        #expect(store.cursor() == 600)
        #expect(sync.incoming.count == 2)
    }

    /// A server that says "more" without moving the cursor can't spin the client.
    @Test func aStuckCursorEndsTheRefresh() async {
        let (t, sync, _) = rig()
        for _ in 0..<5 { await t.queueFeed(page([], hasMore: true, rev: 3, loadFrom: 1)) }
        await sync.refresh()
        #expect(await t.count("feed") == 2)   // the first page, then one that didn't move
    }
}
