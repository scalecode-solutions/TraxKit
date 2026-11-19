import Foundation
import Testing
@testable import TraxKit

@Suite struct ErrorMappingTests {
    @Test func connectErrorsKeepTheirCodeAndStatus() {
        let cases: [(String, Int, Bool)] = [
            ("unauthenticated", 401, true),
            ("unavailable", 503, true),
            ("deadline_exceeded", 504, true),
            ("resource_exhausted", 429, true),
            ("internal", 500, true),
            ("invalid_argument", 400, false),
            ("not_found", 404, false),
            ("already_exists", 409, false),
            ("permission_denied", 403, false),
            ("failed_precondition", 400, false),
        ]
        for (name, status, retry) in cases {
            let e = ConnectTraxTransport.traxError(codeName: name, message: "m")
            #expect(e.code == name)
            #expect(e.httpStatus == status, "\(name)")
            #expect(e.isRetryable == retry, "\(name)")
        }
    }

    @Test func transportErrorsSortByWhatToDo() {
        #expect(TraxTransportError.network("x").isRetryable)
        #expect(TraxTransportError.notAuthenticated.isRetryable)
        #expect(TraxTransportError.badResponse(status: 502).isRetryable)
        #expect(TraxTransportError.badResponse(status: 429).isRetryable)
        #expect(!TraxTransportError.badResponse(status: 404).isRetryable)
        #expect(!TraxTransportError.decoding("x").isRetryable)
    }
}

@MainActor
@Suite struct TrackRetryTests {
    let me = UUID(), friend = UUID()

    func sharingRig() async -> (FakeTraxTransport, TraxSync) {
        let t = FakeTraxTransport()
        await t.setOutgoing([Fixtures.share(owner: me, viewer: friend)])
        let sync = TraxSync(transport: t, store: TraxStore(inMemory: true), currentUserID: me)
        await sync.refreshOutgoing()
        return (t, sync)
    }

    func fix(_ lat: Double) -> TraxFix {
        TraxFix(lat: lat, lng: -90, horizontalAccuracy: 5, timestamp: Date())
    }

    func settle(_ t: FakeTraxTransport, calls: Int) async {
        for _ in 0..<200 where await t.count("track") < calls { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
    }

    /// A failed post doesn't spend the throttle: the next fix goes out at once,
    /// and it's the newest one that's delivered.
    @Test func failedPostIsRetriedWithTheNewestFix() async {
        let (t, sync) = await sharingRig()
        await t.fail("track", with: TraxTransportError.network("offline"))
        sync.ingestFix(fix(30))
        await settle(t, calls: 1)
        sync.ingestFix(fix(31))   // inside the 5 s throttle window, but nothing was delivered yet
        await settle(t, calls: 2)
        #expect(await t.tracked.map(\.lat) == [31])
    }

    /// With no new fix, the poll delivers the one that failed.
    @Test func pendingFixGoesOutOnThePoll() async {
        let (t, sync) = await sharingRig()
        await t.fail("track", with: TraxError(error: .init(code: "unavailable", reason: nil, message: "")))
        sync.ingestFix(fix(30))
        await settle(t, calls: 1)
        sync.flushPendingTrack()
        await settle(t, calls: 2)
        #expect(await t.tracked.map(\.lat) == [30])
        #expect(sync.lastTrackAck != nil)
    }

    /// A refusal that will repeat isn't retried.
    @Test func refusedPostIsDropped() async {
        let (t, sync) = await sharingRig()
        await t.fail("track", with: TraxError(error: .init(code: "invalid_argument", reason: nil, message: "")))
        sync.ingestFix(fix(30))
        await settle(t, calls: 1)
        sync.flushPendingTrack()
        for _ in 0..<50 { await Task.yield() }
        #expect(await t.count("track") == 1)
    }

    /// After a successful post the throttle holds.
    @Test func throttleHoldsAfterSuccess() async {
        let (t, sync) = await sharingRig()
        sync.ingestFix(fix(30))
        await settle(t, calls: 1)
        sync.ingestFix(fix(31))
        for _ in 0..<50 { await Task.yield() }
        #expect(await t.count("track") == 1)
    }
}

@MainActor
@Suite struct BannerAndTransitionTests {
    let me = UUID()

    /// One healthy read mustn't hide another read's persistent failure.
    @Test func aHealthyReadDoesntClearAnotherReadsFailure() async {
        let t = FakeTraxTransport()
        let sync = TraxSync(transport: t, store: TraxStore(inMemory: true), currentUserID: me)
        await t.fail("feed", with: TraxTransportError.network("down"), times: 2)
        await sync.refresh()
        await sync.refresh()
        #expect(sync.lastError != nil)
        await sync.loadPlaces()   // succeeds
        #expect(sync.lastError != nil, "places succeeding cleared the feed's failure")
        await sync.refresh()      // feed recovers
        #expect(sync.lastError == nil)
    }

    /// My own crossing is recorded locally at once; when the server's copy comes
    /// back (another id, a moment later) it replaces the local one, not doubles it.
    @Test func serverCopyOfMyCrossingReplacesTheLocalOne() async {
        let t = FakeTraxTransport()
        let store = TraxStore(inMemory: true)
        let sync = TraxSync(transport: t, store: store, currentUserID: me)
        let bridge = TraxLocationStore(sync: sync, store: store)
        let spot = Fixtures.place(owner: me, name: "Spot", lat: 30, lng: -90)
        await t.setPlaces([spot])
        await sync.loadPlaces()
        await sync.postTransition(placeID: spot.id, event: "enter")
        let local = bridge.myRecentTransitions().first!
        let serverCopy = Fixtures.transition(owner: me, place: spot.id, name: "Spot", event: "enter",
                                             at: local.createdAt + 3000)
        await t.setTransitionsFor([serverCopy])
        await sync.backfillTransitions(ownerID: me)
        #expect(bridge.myRecentTransitions().map(\.id) == [serverCopy.id])
        #expect(sync.recentTransitions.map(\.id) == [serverCopy.id])
    }
}
