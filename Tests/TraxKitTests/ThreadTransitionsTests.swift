import Foundation
import Testing
@testable import TraxKit

/// A conversation's arrivals (MVTRAX-33 K5 + K6): a partner's rows are kept
/// per partner and survive a relaunch; friends' history is only fetched where
/// the server allows it; and my own rows follow the rule the partner's feed
/// applies, so a thread never claims they saw something they didn't.
@MainActor
@Suite struct ThreadTransitionsTests {
    let friend = UUID(), other = UUID(), spot = UUID()

    func rig(store: TraxStore = TraxStore(inMemory: true)) async -> (FakeTraxTransport, TraxEngine, TraxStore, UUID) {
        let t = FakeTraxTransport()
        let me = await t.meContact.id
        let config = TraxConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: me, tokenProvider: { nil })
        return (t, TraxEngine(config: config, host: FakeTraxLocationHost(), transport: t, store: store), store, me)
    }

    @Test func aPartnersRowsAreKeptPerPartnerAndSurviveARelaunch() async {
        let store = TraxStore(inMemory: true)
        let (_, engine, _, _) = await rig(store: store)
        // A busy partner (60 crossings) and a quiet one (1): the quiet one's row
        // used to be pushed out of a shared 50-entry buffer.
        let busy = (0..<60).map { Fixtures.transition(owner: other, place: spot, at: Fixtures.nowMs(TimeInterval(-$0))) }
        store.applyFeedPage(FeedDTO(shares: [], transitions: busy + [Fixtures.transition(owner: friend, place: spot,
                                                                                         at: Fixtures.nowMs(-3600))],
                                    syncTs: Fixtures.nowMs(), hasMore: false, stoppedIds: nil))
        store.save()
        #expect(engine.recentTransitions(with: friend).count == 1)
        #expect(engine.recentTransitions(with: other, limit: 100).count == 60)

        let (_, relaunched, _, _) = await rig(store: store)   // same store, a new engine
        #expect(relaunched.recentTransitions(with: friend).count == 1, "rows survive a relaunch")
    }

    @Test func historyIsFetchedOnlyFromAnExactShare() async {
        let (t, engine, store, me) = await rig()
        await t.setTransitionsFor([Fixtures.transition(owner: friend, place: spot)])
        store.applyFeedPage(FeedDTO(shares: [Fixtures.share(owner: friend, viewer: me, precision: "place")],
                                    syncTs: Fixtures.nowMs(), hasMore: false, stoppedIds: nil))
        store.save(); engine.sync.publish()
        await engine.backfillTransitions(with: friend)
        #expect(await t.count("transitionsFor") == 0, "a place share has no history: don't ask")
        #expect(engine.lastError == nil)

        store.applyFeedPage(FeedDTO(shares: [Fixtures.share(owner: friend, viewer: me, precision: "exact")],
                                    syncTs: Fixtures.nowMs(), hasMore: false, stoppedIds: nil))
        store.save(); engine.sync.publish()
        await engine.backfillTransitions(with: friend)
        #expect(await t.count("transitionsFor") == 1)
        #expect(engine.recentTransitions(with: friend).count == 1, "backfilled rows are stored")
    }

    /// My rows: only while I share with them at exact or place, and only since
    /// that share started.
    @Test(arguments: [("exact", true), ("place", true), ("approx", false)])
    func myRowsFollowMyShare(precision: String, shown: Bool) async throws {
        let (t, engine, store, me) = await rig()
        let place = try await engine.addPlace(TraxPlaceDraft(name: "Home", latitude: 30, longitude: -90))
        try await engine.startSharing(with: friend, precision: TraxPrecision(rawValue: precision)!)
        let started = try #require(engine.outgoingShares.first?.startedAt)
        let startedMs = Int64(started.timeIntervalSince1970 * 1000)
        // One crossing after the share started, one before it.
        store.upsertTransition(Fixtures.transition(owner: me, place: place.id, at: startedMs + 1000))
        store.upsertTransition(Fixtures.transition(owner: me, place: place.id, event: "leave", at: startedMs - 1000))
        store.save(); engine.sync.publish()
        _ = t

        let mine = engine.threadTransitions(with: friend).filter { $0.ownerId == me }
        #expect(mine.count == (shown ? 1 : 0))
        #expect(mine.allSatisfy { $0.createdAt >= startedMs }, "nothing from before the share")
    }

    @Test func noShareShowsOnlyTheirs() async {
        let (_, engine, store, me) = await rig()
        store.applyFeedPage(FeedDTO(shares: [], transitions: [Fixtures.transition(owner: friend, place: spot)],
                                    syncTs: Fixtures.nowMs(), hasMore: false, stoppedIds: nil))
        store.upsertTransition(Fixtures.transition(owner: me, place: spot))
        store.save(); engine.sync.publish()
        let rows = engine.threadTransitions(with: friend)
        #expect(rows.map(\.ownerId) == [friend])
    }

    @Test func bothSidesMergeNewestFirst() async throws {
        let (_, engine, store, me) = await rig()
        let place = try await engine.addPlace(TraxPlaceDraft(name: "Home", latitude: 30, longitude: -90))
        try await engine.startSharing(with: friend, precision: .exact)
        let now = Fixtures.nowMs()
        store.applyFeedPage(FeedDTO(shares: [], transitions: [Fixtures.transition(owner: friend, place: spot, at: now + 2000)],
                                    syncTs: now, hasMore: false, stoppedIds: nil))
        store.upsertTransition(Fixtures.transition(owner: me, place: place.id, at: now + 1000))
        store.upsertTransition(Fixtures.transition(owner: me, place: place.id, at: now + 3000))
        store.save(); engine.sync.publish()
        let rows = engine.threadTransitions(with: friend)
        #expect(rows.map(\.createdAt) == [now + 3000, now + 2000, now + 1000])
    }
}
