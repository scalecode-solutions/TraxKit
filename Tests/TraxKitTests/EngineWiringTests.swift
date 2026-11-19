import Foundation
import Testing
@testable import TraxKit

/// The engine wired to a fake device: what it asks the device for, what it
/// posts, and how holds drive the feed poll.
@MainActor
@Suite struct EngineWiringTests {
    let me = UUID(), friend = UUID()

    func rig(sharing: Bool = false) async -> (FakeTraxTransport, FakeTraxLocationHost, TraxEngine) {
        let t = FakeTraxTransport()
        if sharing { await t.setOutgoing([Fixtures.share(owner: me, viewer: friend)]) }
        let host = FakeTraxLocationHost()
        let config = TraxConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: me, tokenProvider: { nil })
        let engine = TraxEngine(config: config, host: host, transport: t, store: TraxStore(inMemory: true))
        return (t, host, engine)
    }

    /// Waits (briefly, in real time) until `cond` holds.
    func eventually(_ cond: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await cond()
    }

    @Test func notSharingAsksForNoTracking() async {
        let (_, host, engine) = await rig()
        engine.start()
        #expect(await eventually { host.lastDemand != nil })
        #expect(host.lastDemand == .off)
        engine.stop()
    }

    @Test func sharingAsksForTrackingAndPostsFixes() async {
        let (t, host, engine) = await rig(sharing: true)
        engine.start()
        #expect(await eventually { host.lastDemand == .continuous })
        host.send(TraxFix(lat: 30, lng: -90, horizontalAccuracy: 5, timestamp: Date()))
        #expect(await eventually { await t.count("track") == 1 })
        #expect(engine.currentFix?.lat == 30)
        engine.stop()
        #expect(host.lastDemand == .off)
        #expect(host.lastRegions == [])
    }

    /// Sharing ended by the server's word (an ack saying no shares remain):
    /// demand drops without waiting for a poll tick.
    @Test func ackEndingSharingDropsDemand() async {
        let (t, host, engine) = await rig(sharing: true)
        engine.start()
        #expect(await eventually { host.lastDemand == .continuous })
        engine.setForeground(false)   // no ticks from here on
        #expect(host.lastDemand == .significant)
        await t.setTrackAck(TrackAckDTO(ok: true, shares: 0, ts: 0))
        host.send(TraxFix(lat: 30, lng: -90, horizontalAccuracy: 5, timestamp: Date()))
        #expect(await eventually { host.lastDemand == .off })
        engine.stop()
    }

    /// A share reaching its expiresAt drops demand on its own, with no tick or ack.
    @Test func expiryDropsDemand() async {
        let t = FakeTraxTransport()
        await t.setOutgoing([Fixtures.share(owner: me, viewer: friend,
                                            expiresAt: Int64(Date().timeIntervalSince1970 * 1000) + 600)])
        let host = FakeTraxLocationHost()
        let config = TraxConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: me, tokenProvider: { nil })
        let engine = TraxEngine(config: config, host: host, transport: t, store: TraxStore(inMemory: true))
        engine.start()
        #expect(await eventually { host.lastDemand == .continuous })
        engine.setForeground(false)
        #expect(await eventually { host.lastDemand == .off })
        engine.stop()
    }

    @Test func placesBecomeRegionsAndCrossingsArePosted() async {
        let (t, host, engine) = await rig()
        let place = Fixtures.place(owner: me, name: "Spot", lat: 30, lng: -90)
        await t.setPlaces([place])
        engine.start()
        #expect(await eventually { host.lastRegions?.map(\.placeID) == [place.id] })
        host.cross(place.id, .enter)
        #expect(await eventually { await t.postedTransitions.count == 1 })
        #expect(await t.postedTransitions.first?.placeId == place.id)
        #expect(engine.bridge.myRecentTransitions().first?.placeId == place.id)
        engine.stop()
    }

    /// A screen acquiring the engine refreshes at once, not on the next tick.
    @Test func acquireRefreshesNow() async {
        let (t, _, engine) = await rig()
        engine.start()
        #expect(await eventually { await t.count("feed") == 1 })   // the first poll
        engine.acquire()
        #expect(await eventually { await t.count("feed") == 2 })   // well inside the 5 s cadence
        engine.release()
        engine.stop()
    }

    @Test func comingBackToTheForegroundRefreshesNow() async {
        let (t, _, engine) = await rig()
        engine.start()
        #expect(await eventually { await t.count("feed") == 1 })
        engine.setForeground(false)
        engine.setForeground(true)
        #expect(await eventually { await t.count("feed") == 2 })
        engine.stop()
    }

    /// Held (and in the foreground): the fast cadence; unheld in the foreground:
    /// the slow one; in the background: no poll (FeedCadencePolicy).
    @Test func holdsSetTheCadence() async {
        let (_, _, engine) = await rig()
        #expect(engine.pollInterval() == FeedCadencePolicy.foregroundUnheld)
        engine.acquire(); engine.acquire()
        #expect(engine.pollInterval() == FeedCadencePolicy.held)
        engine.release()
        #expect(engine.pollInterval() == FeedCadencePolicy.held)   // one screen still holds it
        engine.setForeground(false)
        #expect(engine.pollInterval() == nil)
        engine.setForeground(true); engine.release()
        #expect(engine.pollInterval() == FeedCadencePolicy.foregroundUnheld)
        engine.release()                                 // an extra release can't go negative
        #expect(engine.holders == 0)
    }
}
