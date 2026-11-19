import Foundation
import CoreLocation
import Testing
@testable import TraxKit

/// Truth tables for the lifetime policies (pure functions).
@Suite struct PolicyTests {
    @Test func trackingDemandTable() {
        typealias Row = (p: Set<TraxPrecision>, auth: TraxLocationAuth, fg: Bool, want: TraxTrackingDemand)
        let rows: [Row] = [
            ([], .always, true, .off),                        // not sharing: off
            ([], .whenInUse, false, .off),
            ([.exact], .denied, true, .off),                  // no permission: off
            ([.exact], .notDetermined, true, .off),
            // exact: full rate, foreground and background, either permission
            ([.exact], .whenInUse, true, .continuous),
            ([.exact], .whenInUse, false, .continuous),
            ([.exact], .always, true, .continuous),
            ([.exact], .always, false, .continuous),
            // place: coarse while open, significant-change in the background
            ([.place], .always, true, .coarse),
            ([.place], .always, false, .significant),
            ([.place], .whenInUse, false, .significant),
            // approx: ~1 km while open, significant-change in the background
            ([.approx], .whenInUse, true, .approximate),
            ([.approx], .always, false, .significant),
            // the most precise live share sets the tier
            ([.approx, .place], .always, true, .coarse),
            ([.approx, .exact], .always, false, .continuous),
            ([.place, .exact, .approx], .whenInUse, true, .continuous),
            ([.place, .approx], .always, false, .significant),
        ]
        for r in rows {
            #expect(TrackingDemandPolicy.demand(precisions: r.p, auth: r.auth, foreground: r.fg) == r.want, "\(r)")
        }
    }

    /// What CoreLocation is asked for per tier: only exact keeps updating in the
    /// background, and only when the host declares the location background mode.
    @Test func updateProfileTable() {
        typealias E = TraxLocationEngine
        #expect(E.profile(for: .off, stationary: false, hasBackgroundMode: true) == nil)
        #expect(E.profile(for: .significant, stationary: false, hasBackgroundMode: true) == nil)
        let approx = E.profile(for: .approximate, stationary: false, hasBackgroundMode: true)
        #expect(approx?.accuracy == kCLLocationAccuracyKilometer && approx?.background == false)
        let coarse = E.profile(for: .coarse, stationary: false, hasBackgroundMode: true)
        #expect(coarse?.accuracy == kCLLocationAccuracyHundredMeters && coarse?.background == false)
        let moving = E.profile(for: .continuous, stationary: false, hasBackgroundMode: true)
        #expect(moving?.accuracy == kCLLocationAccuracyBest && moving?.background == true)
        let still = E.profile(for: .continuous, stationary: true, hasBackgroundMode: true)
        #expect(still?.accuracy == kCLLocationAccuracyHundredMeters && still?.background == true)
        let noMode = E.profile(for: .continuous, stationary: false, hasBackgroundMode: false)
        #expect(noMode?.background == false, "without the location background mode, never ask (it would crash)")
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
