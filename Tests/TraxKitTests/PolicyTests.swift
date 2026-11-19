import Foundation
import Testing
@testable import TraxKit

/// Truth tables for the lifetime policies (pure functions).
@Suite struct PolicyTests {
    @Test func trackingDemandTable() {
        typealias Row = (sharing: Bool, auth: TraxLocationAuth, fg: Bool, optIn: Bool, want: TraxTrackingDemand)
        let rows: [Row] = [
            (false, .always, true, false, .off),            // not sharing: off
            (false, .always, false, true, .off),
            (true, .denied, true, false, .off),             // no permission: off
            (true, .notDetermined, true, false, .off),
            (true, .whenInUse, true, false, .continuous),   // sharing, foreground
            (true, .always, true, false, .continuous),
            (true, .always, false, false, .significant),    // background, no opt-in: quiet
            // When-In-Use + background → significant, which iOS delivers nothing
            // for in the background: the intended quiet default until step 10.
            (true, .whenInUse, false, false, .significant),
            (true, .always, false, true, .continuous),      // background with opt-in
        ]
        for r in rows {
            #expect(TrackingDemandPolicy.demand(sharing: r.sharing, auth: r.auth, foreground: r.fg,
                                                backgroundOptIn: r.optIn) == r.want, "\(r)")
        }
    }

    @Test func shareLivenessTable() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let past = Int64(999_000 * 1000), future = Int64(1_001_000 * 1000)
        typealias Row = (exp: [Int64?], ack: Int?, ackNewer: Bool, want: Bool)
        let rows: [Row] = [
            ([], nil, false, false),           // no outgoing share
            ([nil], nil, false, true),         // until-stopped share
            ([future], nil, false, true),
            ([past], nil, false, false),       // expired locally
            ([past, future], nil, false, true),
            ([nil], 0, true, false),           // the fresher ack says no shares: stop
            ([nil], 0, false, true),           // outgoing refreshed after that ack: trust it
            ([nil], 2, true, true),
        ]
        for r in rows {
            #expect(ShareLivenessPolicy.shouldPost(outgoingExpiries: r.exp, activeSharesInLastAck: r.ack,
                                                   ackNewerThanOutgoing: r.ackNewer, now: now) == r.want, "\(r)")
        }
    }

    @Test func feedCadenceTable() {
        #expect(FeedCadencePolicy.interval(holds: 1, foreground: true) == .seconds(5))
        #expect(FeedCadencePolicy.interval(holds: 3, foreground: true) == .seconds(5))
        #expect(FeedCadencePolicy.interval(holds: 0, foreground: true) == .seconds(30))
        #expect(FeedCadencePolicy.interval(holds: 1, foreground: false) == nil)
        #expect(FeedCadencePolicy.interval(holds: 0, foreground: false) == nil)
    }
}

/// The producer's own "am I sharing" truth: a fix's ack saying my shares are
/// gone (stopped from another device) stops posting without waiting for a
/// feed poll; the next outgoing refresh is the word after that.
@MainActor
@Suite struct ProducerLivenessTests {
    let me = UUID(), friend = UUID()

    @Test func ackWithNoSharesStopsPosting() async {
        let t = FakeTraxTransport()
        await t.setOutgoing([Fixtures.share(owner: me, viewer: friend)])
        let sync = TraxSync(transport: t, store: TraxStore(inMemory: true), currentUserID: me)
        await sync.refreshOutgoing()
        await t.setTrackAck(TrackAckDTO(ok: true, shares: 0, ts: 0))   // stopped elsewhere

        sync.ingestFix(TraxFix(lat: 30, lng: -90, timestamp: Date()))
        for _ in 0..<200 where await t.count("track") < 1 { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(!sync.isSharing, "the ack said no shares remain")

        sync.ingestFix(TraxFix(lat: 31, lng: -90, timestamp: Date().addingTimeInterval(120)))   // far, later
        for _ in 0..<50 { await Task.yield() }
        #expect(await t.count("track") == 1, "posted after the server said sharing ended")

        await sync.refreshOutgoing()   // outgoing still lists the share: it's the fresher word now
        #expect(sync.isSharing)
    }
}
