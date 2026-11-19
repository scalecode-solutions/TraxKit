import Foundation
import Testing
@testable import TraxKit

/// The engine's public API: what a host does through it, end to end on a fake
/// transport.
@MainActor
@Suite struct EngineAPITests {
    let friend = UUID(), other = UUID()

    func rig() async -> (FakeTraxTransport, TraxEngine) {
        let t = FakeTraxTransport()
        let config = TraxConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: await t.meContact.id, tokenProvider: { nil })
        let engine = TraxEngine(config: config, host: FakeTraxLocationHost(), transport: t, store: TraxStore(inMemory: true))
        return (t, engine)
    }

    @Test func startAndStopSharingWithOnePerson() async throws {
        let (t, engine) = await rig()
        try await engine.startSharing(with: friend, precision: .place, duration: .seconds(3600))
        try await engine.startSharing(with: other)
        #expect(Set(engine.outgoingShares.map(\.viewerID)) == [friend, other])
        #expect(engine.relationship(with: friend).iShare)

        try await engine.stopSharing(with: friend)
        #expect(engine.outgoingShares.map(\.viewerID) == [other], "only the named person's share stops")
        #expect(!engine.relationship(with: friend).iShare)
        try await engine.stopSharing(with: friend)   // nothing to stop: no call, no throw
        #expect(await t.count("stopShare") == 1)
    }

    @Test func startSharingSendsPrecisionAndDuration() async throws {
        let (t, engine) = await rig()
        try await engine.startSharing(with: friend, precision: .approx, duration: .seconds(900))
        let body = try #require(await t.lastStartShare)
        #expect(body.precision == "approx")
        #expect(body.expiresIn == 900)
        try await engine.startSharing(with: friend)   // change the live share: until I stop
        #expect(await t.lastStartShare?.expiresIn == nil)
    }

    @Test func placesAreValuesAndMineIsMarked() async throws {
        let (_, engine) = await rig()
        let made = try await engine.addPlace(TraxPlaceDraft(name: "Gym", emoji: "💪", latitude: 30, longitude: -90))
        #expect(made.name == "Gym" && made.isMine)
        #expect(engine.places.map(\.id) == [made.id])
        try await engine.sharePlace(made.id, with: friend)
        #expect(engine.sharedPlaces(with: friend).map(\.id) == [made.id])
        try await engine.deletePlace(made.id)
        #expect(engine.places.isEmpty)
    }

    @Test func peopleIncludesMeAndFriends() async throws {
        let (t, engine) = await rig()
        await t.setContacts([TraxContact(id: friend, name: "Friend")])
        await engine.sync.loadContacts()
        #expect(engine.people[friend]?.name == "Friend")
        #expect(engine.people[engine.currentUserID]?.name == "Me")
    }

    @Test func placeKindAndAddressRoundTrip() async throws {
        let (t, engine) = await rig()
        let made = try await engine.addPlace(TraxPlaceDraft(kind: .home, name: "Home", latitude: 30, longitude: -90,
                                                            address: "1 Main St"))
        #expect(await t.lastPlaceBody?.type == "home")
        #expect(await t.lastPlaceBody?.address == "1 Main St")
        #expect(made.kind == .home && made.address == "1 Main St")
    }

    /// Clearing history drops my own crossings here too, not only on the server.
    @Test func clearHistoryDropsMyLocalCrossings() async throws {
        let (t, engine) = await rig()
        let place = try await engine.addPlace(TraxPlaceDraft(name: "Home", latitude: 30, longitude: -90))
        await engine.sync.postTransition(placeID: place.id, event: "enter")
        #expect(engine.myRecentTransitions().count == 1)

        try await engine.clearHistory()
        #expect(await t.count("clearHistory") == 1)
        #expect(engine.myRecentTransitions().isEmpty)
    }

    @Test func clearHistoryBeforeACutoffKeepsNewerCrossings() async throws {
        let (_, engine) = await rig()
        let place = try await engine.addPlace(TraxPlaceDraft(name: "Home", latitude: 30, longitude: -90))
        await engine.sync.postTransition(placeID: place.id, event: "enter")
        try await engine.clearHistory(before: Date().addingTimeInterval(-3600))
        #expect(engine.myRecentTransitions().count == 1, "an hour-old cutoff keeps a crossing from just now")
    }

    @Test func clearHistoryFailureLeavesLocalAlone() async throws {
        let (t, engine) = await rig()
        let place = try await engine.addPlace(TraxPlaceDraft(name: "Home", latitude: 30, longitude: -90))
        await engine.sync.postTransition(placeID: place.id, event: "enter")
        await t.fail("clearHistory", with: TraxTransportError.badResponse(status: 500))
        await #expect(throws: TraxTransportError.self) { try await engine.clearHistory() }
        #expect(engine.myRecentTransitions().count == 1, "nothing cleared here when the server didn't clear")
    }
}
