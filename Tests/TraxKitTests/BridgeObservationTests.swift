import Foundation
import Observation
import Testing
@testable import TraxKit

/// The host's per-person surfaces (a person map, a conversation header, list
/// badges) read the bridge inside a view body. A view only re-renders when
/// something it read changes, so every bridge read must be observable: these
/// tests read it the way a body does (inside `withObservationTracking`), then let
/// the poll change the data, and require that the read is invalidated.
@MainActor
@Suite struct BridgeObservationTests {
    let me = UUID(), friend = UUID()

    final class Fired: @unchecked Sendable { var value = false }

    /// Reads like a view body; reports whether `change` invalidated the read.
    func invalidates(_ read: () -> Void, by change: () async -> Void) async -> Bool {
        let fired = Fired()
        withObservationTracking { read() } onChange: { fired.value = true }
        await change()
        return fired.value
    }

    func rig() async -> (FakeTraxTransport, TraxSync, TraxLocationStore) {
        let t = FakeTraxTransport()
        let store = TraxStore(inMemory: true)
        let sync = TraxSync(transport: t, store: store, currentUserID: me)
        return (t, sync, TraxLocationStore(sync: sync, store: store))
    }

    @Test func sharerMovingUpdatesTheReader() async {
        let (t, sync, bridge) = await rig()
        let shareID = UUID()
        await t.queueFeed(Fixtures.page([Fixtures.share(id: shareID, owner: friend, viewer: me, lat: 30, lng: -90)]))
        await sync.refresh()
        #expect(bridge.summary(for: friend)?.coordinate?.latitude == 30)

        await t.queueFeed(Fixtures.page([Fixtures.share(id: shareID, owner: friend, viewer: me, lat: 31, lng: -90)]))
        let fired = await invalidates({ _ = bridge.relationship(with: friend).incoming?.coordinate }) {
            await sync.refresh()
        }
        #expect(fired, "a poll that moved the sharer must invalidate a view reading the bridge")
        #expect(bridge.summary(for: friend)?.coordinate?.latitude == 31)
    }

    @Test func shareStartingAfterTheViewOpenedUpdatesTheReader() async {
        let (t, sync, bridge) = await rig()
        #expect(bridge.summary(for: friend) == nil)
        await t.queueFeed(Fixtures.page([Fixtures.share(owner: friend, viewer: me, lat: 30, lng: -90)]))
        let fired = await invalidates({ _ = bridge.summary(for: friend) }) { await sync.refresh() }
        #expect(fired, "a share that starts while the view is open must show up")
        #expect(bridge.summary(for: friend) != nil)
    }

    @Test func restartedShareUpdatesTheReader() async {
        let (t, sync, bridge) = await rig()
        let first = UUID()
        await t.queueFeed(Fixtures.page([Fixtures.share(id: first, owner: friend, viewer: me, lat: 30, lng: -90)]))
        await sync.refresh()
        await t.queueFeed(Fixtures.page([Fixtures.share(owner: friend, viewer: me, lat: 35, lng: -90)], stopped: [first]))
        let fired = await invalidates({ _ = bridge.summary(for: friend)?.coordinate }) { await sync.refresh() }
        #expect(fired, "a stopped-and-restarted share (new id) must update the view")
        #expect(bridge.summary(for: friend)?.coordinate?.latitude == 35)
    }

    @Test func stoppedShareClearsTheReader() async {
        let (t, sync, bridge) = await rig()
        let id = UUID()
        await t.queueFeed(Fixtures.page([Fixtures.share(id: id, owner: friend, viewer: me, lat: 30, lng: -90)]))
        await sync.refresh()
        await t.queueFeed(Fixtures.page([], stopped: [id]))
        let fired = await invalidates({ _ = bridge.summary(for: friend) }) { await sync.refresh() }
        #expect(fired)
        #expect(bridge.summary(for: friend) == nil)
    }

    @Test func sharedPlacesUpdateTheReader() async {
        let (t, sync, bridge) = await rig()
        #expect(bridge.sharedPlaces(with: friend).isEmpty)
        await t.setPlaces([Fixtures.place(owner: me, name: "Spot", lat: 30, lng: -90, sharedWith: [friend])])
        let fired = await invalidates({ _ = bridge.sharedPlaces(with: friend) }) { await sync.loadPlaces() }
        #expect(fired)
        #expect(bridge.sharedPlaces(with: friend).map(\.name) == ["Spot"])
    }

    @Test func ownCrossingUpdatesMyTransitions() async {
        let (t, sync, bridge) = await rig()
        let spot = Fixtures.place(owner: me, name: "Spot", lat: 30, lng: -90)
        await t.setPlaces([spot])
        await sync.loadPlaces()
        let fired = await invalidates({ _ = bridge.myRecentTransitions() }) {
            await sync.postTransition(placeID: spot.id, event: "enter")
        }
        #expect(fired)
        #expect(bridge.myRecentTransitions().first?.placeName == "Spot")
    }
}
