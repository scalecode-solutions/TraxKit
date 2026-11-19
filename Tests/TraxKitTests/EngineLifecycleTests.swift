import Foundation
import Testing
@testable import TraxKit

/// A host location engine that does nothing: streams that never yield.
@MainActor
final class SilentHost: TraxLocationHost {
    var currentFix: TraxFix? { nil }
    var authorization: TraxLocationAuth { .whenInUse }
    private var fixCont: AsyncStream<TraxFix>.Continuation?
    private var crossingCont: AsyncStream<TraxTransition>.Continuation?
    func fixStream() -> AsyncStream<TraxFix> { AsyncStream { self.fixCont = $0 } }
    func transitionStream() -> AsyncStream<TraxTransition> { AsyncStream { self.crossingCont = $0 } }
    func requestLocationAccess() {}
    func setMonitoredRegions(_ regions: [TraxRegion]) {}
    private(set) var lastDemand: TraxTrackingDemand?
    func setDesiredTracking(_ demand: TraxTrackingDemand) { lastDemand = demand }
    func send(_ fix: TraxFix) { fixCont?.yield(fix) }
}

@MainActor
@Suite struct EngineLifecycleTests {
    let me = UUID(), friend = UUID()

    func rig() -> (FakeTraxTransport, TraxSync, TraxStore) {
        let t = FakeTraxTransport()
        let store = TraxStore(inMemory: true)
        return (t, TraxSync(transport: t, store: store, currentUserID: me), store)
    }

    /// A refresh still waiting on the network when the user signs out must not
    /// write the signed-out account's data back into the wiped store.
    @Test func wipeDuringRefreshWritesNothingBack() async {
        let (t, sync, store) = rig()
        await t.queueFeed(Fixtures.page([Fixtures.share(owner: friend, viewer: me, lat: 30, lng: -90)]))
        await t.hold("feed")
        let refresh = Task { await sync.refresh() }
        while await t.count("feed") == 0 { await Task.yield() }
        sync.wipe()
        await t.release("feed")
        await refresh.value
        #expect(store.incomingShare(ownerID: friend) == nil, "wiped store got the old page back")
        #expect(sync.incoming.isEmpty)
        #expect(store.cursor() == 0)
    }

    @Test func stopDuringRefreshWritesNothing() async {
        let (t, sync, store) = rig()
        await t.queueFeed(Fixtures.page([Fixtures.share(owner: friend, viewer: me, lat: 30, lng: -90)]))
        await t.hold("feed")
        let refresh = Task { await sync.refresh() }
        while await t.count("feed") == 0 { await Task.yield() }
        sync.invalidate()
        await t.release("feed")
        await refresh.value
        #expect(store.incomingShare(ownerID: friend) == nil)
    }

    @Test func nothingWritesAfterAWipeUntilResume() async {
        let (t, sync, store) = rig()
        sync.wipe()
        await t.queueFeed(Fixtures.page([Fixtures.share(owner: friend, viewer: me, lat: 30, lng: -90)]))
        await sync.refresh()
        #expect(await t.count("feed") == 0, "a wiped sync must not even fetch")
        sync.resume()
        await sync.refresh()
        #expect(store.incomingShare(ownerID: friend) != nil)
    }

    /// A caller arriving while a refresh runs waits for it (and the extra pass
    /// its request needs) instead of returning at once with stale data.
    @Test func concurrentRefreshWaitsForFreshData() async {
        let (t, sync, _) = rig()
        await t.hold("feed")
        let first = Task { await sync.refresh() }
        while await t.count("feed") == 0 { await Task.yield() }
        await t.queueFeed(Fixtures.page([Fixtures.share(owner: friend, viewer: me, lat: 30, lng: -90)]))
        final class Done: @unchecked Sendable { var value = false }
        let done = Done()
        let second = Task { await sync.refresh(); done.value = true }
        for _ in 0..<50 { await Task.yield() }
        #expect(!done.value, "the second caller returned before any data arrived")
        await t.release("feed")
        await first.value
        await second.value
        #expect(sync.incoming[friend] != nil)
        #expect(await t.count("feed") == 2, "one run plus one coalesced re-run")
    }

    /// Dropping a started engine without stop() must not leak it.
    @Test func droppedEngineIsFreed() async {
        let (t, _, store) = rig()
        let config = TraxConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: me, tokenProvider: { nil })
        var engine: TraxEngine? = TraxEngine(config: config, host: SilentHost(), transport: t, store: store)
        weak let weakEngine = engine
        engine?.start()
        for _ in 0..<20 { await Task.yield() }
        engine = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(weakEngine == nil, "a started engine kept itself alive")
    }

    /// A host that drops a started engine without stop() doesn't leave the
    /// device tracking for nobody.
    @Test func droppedEngineTurnsTrackingOff() async {
        let (t, _, store) = rig()
        let host = SilentHost()
        let config = TraxConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: me, tokenProvider: { nil })
        var engine: TraxEngine? = TraxEngine(config: config, host: host, transport: t, store: store)
        engine?.start()
        for _ in 0..<20 { await Task.yield() }
        host.setDesiredTracking(.continuous)   // as if sharing had started
        engine = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(host.lastDemand == .off)
    }

    /// If page 2 of a feed fails, what page 1 applied is still published.
    @Test func partialFeedFailureStillPublishes() async {
        let (t, sync, _) = rig()
        await t.queueFeed(Fixtures.page([Fixtures.share(owner: friend, viewer: me, lat: 30, lng: -90)], hasMore: true))
        await t.fail("feed", with: TraxTransportError.network("dropped"), onCallNumber: 2)
        await sync.refresh()
        #expect(sync.incoming[friend] != nil, "page 1 was applied but never published")
    }
}
