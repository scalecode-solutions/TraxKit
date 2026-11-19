import Foundation
import Testing
@testable import TraxKit

/// What the kit's views read now that none of them queries SwiftData: values
/// TraxSync publishes after each load, observable from a view body.
@MainActor
@Suite struct PublishedStateTests {
    let me = UUID()

    func rig() -> (FakeTraxTransport, TraxSync) {
        let t = FakeTraxTransport()
        return (t, TraxSync(transport: t, store: TraxStore(inMemory: true), currentUserID: me))
    }

    func observed(_ read: () -> Void) -> () -> Bool {
        let fired = BridgeObservationTests.Fired()
        withObservationTracking { read() } onChange: { fired.value = true }
        return { fired.value }
    }

    @Test func contactsArePublishedByNameIncludingMe() async {
        let (t, sync) = rig()
        await t.setContacts([TraxContact(id: UUID(), name: "Zed"), TraxContact(id: UUID(), name: "Amy")])
        await t.setMe(TraxContact(id: me, name: "Me"))
        let fired = observed { _ = sync.contacts }
        await sync.loadContacts()
        #expect(fired())
        #expect(sync.contacts.map(\.name) == ["Amy", "Me", "Zed"])
    }

    @Test func sharersAreListedNewestFirst() async {
        let (t, sync) = rig()
        let a = UUID(), b = UUID()
        await t.queueFeed(Fixtures.page([
            Fixtures.share(owner: a, viewer: me, lat: 1, lng: 1, at: Fixtures.nowMs(-120)),
            Fixtures.share(owner: b, viewer: me, lat: 2, lng: 2, at: Fixtures.nowMs(-10)),
        ]))
        let fired = observed { _ = sync.incomingList }
        await sync.refresh()
        #expect(fired())
        #expect(sync.incomingList.map(\.ownerID) == [b, a])
    }

    @Test func placesCarryWhatTheEditorNeeds() async {
        let (t, sync) = rig()
        let friend = UUID()
        await t.setPlaces([Fixtures.place(owner: me, name: "Spot", lat: 1, lng: 2, sharedWith: [friend])])
        await sync.loadPlaces()
        let p = try! #require(sync.placeSnapshots.first)
        #expect(p.type == "custom" && p.isShared && p.sharedWith == [friend] && p.ownerID == me)
    }
}
