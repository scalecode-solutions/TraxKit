import Foundation
import Testing
@testable import TraxKit

/// What a fix carries to the server: its own time as `recordedAt`, and the
/// fallback when the server refuses the device's clock.
@MainActor
@Suite struct TrackTimestampTests {
    let me = UUID(), friend = UUID()

    func sharingRig() async -> (FakeTraxTransport, TraxSync) {
        let t = FakeTraxTransport()
        await t.setOutgoing([Fixtures.share(owner: me, viewer: friend)])
        let sync = TraxSync(transport: t, store: TraxStore(inMemory: true), currentUserID: me)
        await sync.refreshOutgoing()
        return (t, sync)
    }

    func settle(_ t: FakeTraxTransport, calls: Int) async {
        for _ in 0..<200 where await t.count("track") < calls { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
    }

    static let future = TraxError(error: .init(code: "invalid_argument", reason: nil,
                                               message: "recorded_at is in the future"))

    /// The fix's own time goes out as recordedAt (and clientTs), so a fix that
    /// arrives late is still filed under when it was taken.
    @Test func fixCarriesItsOwnTime() async {
        let (t, sync) = await sharingRig()
        let taken = Date(timeIntervalSinceNow: -40)
        sync.ingestFix(TraxFix(lat: 30, lng: -90, horizontalAccuracy: 5, timestamp: taken))
        await settle(t, calls: 1)
        let ms = Int64(taken.timeIntervalSince1970 * 1000)
        let sent = await t.tracked
        #expect(sent.count == 1)
        #expect(sent.first?.recordedAt == ms)
        #expect(sent.first?.clientTs == ms)
    }

    /// A device clock ahead of the server's: the refused fix is resent at once
    /// without recordedAt, and later fixes don't carry it either, rather than
    /// every fix being refused.
    @Test func refusedClockFallsBackToServerTime() async {
        let (t, sync) = await sharingRig()
        await t.fail("track", with: Self.future)
        sync.ingestFix(TraxFix(lat: 30, lng: -90, horizontalAccuracy: 5, timestamp: Date()))
        await settle(t, calls: 2)
        var sent = await t.tracked
        #expect(sent.map(\.lat) == [30])
        #expect(sent.first?.recordedAt == nil)

        sync.ingestFix(TraxFix(lat: 31, lng: -90, horizontalAccuracy: 5, timestamp: Date(timeIntervalSinceNow: 10)))
        sync.flushPendingTrack()
        await settle(t, calls: 3)
        sent = await t.tracked
        // The throttle may hold the second fix; if it went out, it's unstamped.
        #expect(sent.allSatisfy { $0.recordedAt == nil })
    }

    /// Any other refusal is not a clock problem: the fix is dropped, not restamped.
    @Test func otherRefusalsDropTheFix() async {
        let (t, sync) = await sharingRig()
        await t.fail("track", with: TraxError(error: .init(code: "invalid_argument", reason: nil,
                                                           message: "recorded_at is older than history retention")))
        sync.ingestFix(TraxFix(lat: 30, lng: -90, horizontalAccuracy: 5, timestamp: Date()))
        await settle(t, calls: 1)
        sync.flushPendingTrack()
        for _ in 0..<50 { await Task.yield() }
        #expect(await t.count("track") == 1)
        #expect(await t.tracked.isEmpty)
    }
}
