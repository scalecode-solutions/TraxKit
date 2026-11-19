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

    /// Held (and in the foreground): the fast cadence. Otherwise the slow one.
    @Test func holdsSetTheCadence() async {
        let (_, _, engine) = await rig()
        #expect(engine.pollInterval() == .seconds(20))
        engine.acquire(); engine.acquire()
        #expect(engine.pollInterval() == .seconds(5))
        engine.release()
        #expect(engine.pollInterval() == .seconds(5))   // one screen still holds it
        engine.setForeground(false)
        #expect(engine.pollInterval() == .seconds(20))
        engine.setForeground(true); engine.release()
        #expect(engine.pollInterval() == .seconds(20))
        engine.release()                                 // an extra release can't go negative
        #expect(engine.holders == 0)
    }
}
