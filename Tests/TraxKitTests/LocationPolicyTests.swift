import Foundation
import Testing
@testable import TraxKit

/// The upload decision, pinned case by case.
@Suite struct UploadPolicyTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// ~0.00027° of latitude ≈ 30 m, clearly over the 25 m threshold (0.000226°
    /// measured 25.05 m and flaked on rounding); 0.000216° ≈ 24 m, clearly under.
    static let thirtyMetresNorth = 0.00027
    static let twentyFourMetresNorth = 0.000216

    static func fix(lat: Double = 30, motion: String? = "walking", at seconds: TimeInterval) -> TraxFix {
        TraxFix(lat: lat, lng: -90, horizontalAccuracy: 5, motion: motion, timestamp: t0.addingTimeInterval(seconds))
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let last: TraxFix?
        let new: TraxFix
        let now: TimeInterval
        let expected: UploadPolicy.Decision
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "first fix", last: nil, new: fix(at: 0), now: 0, expected: .post),
        Case(name: "still, 30 s later", last: fix(at: 0), new: fix(at: 30), now: 30, expected: .skip),
        Case(name: "still, 89 s later", last: fix(at: 0), new: fix(at: 89), now: 89, expected: .skip),
        Case(name: "still, heartbeat due at 90 s", last: fix(at: 0), new: fix(at: 90), now: 90, expected: .post),
        Case(name: "moved 30 m", last: fix(at: 0), new: fix(lat: 30 + thirtyMetresNorth, at: 10), now: 10, expected: .post),
        Case(name: "moved 24 m", last: fix(at: 0), new: fix(lat: 30 + twentyFourMetresNorth, at: 10), now: 10, expected: .skip),
        Case(name: "moved 10 m", last: fix(at: 0), new: fix(lat: 30.00009, at: 10), now: 10, expected: .skip),
        Case(name: "moved far, but under 5 s", last: fix(at: 0), new: fix(lat: 30.01, at: 3), now: 3, expected: .skip),
        Case(name: "motion changed", last: fix(motion: "walking", at: 0), new: fix(motion: "automotive", at: 10), now: 10, expected: .post),
        Case(name: "came to rest", last: fix(motion: "walking", at: 0), new: fix(motion: "stationary", at: 10), now: 10, expected: .post),
        Case(name: "motion unknown now", last: fix(motion: "walking", at: 0), new: fix(motion: nil, at: 10), now: 10, expected: .skip),
        Case(name: "motion known now", last: fix(motion: nil, at: 0), new: fix(motion: "walking", at: 10), now: 10, expected: .post),
        Case(name: "heartbeat counts from the delivered fix, not the new one",
             last: fix(at: 0), new: fix(at: 100), now: 100, expected: .post),
    ]

    @Test(arguments: cases) func decides(_ c: Case) {
        #expect(UploadPolicy.decide(last: c.last, new: c.new, now: Self.t0.addingTimeInterval(c.now)) == c.expected)
    }
}

/// What reaches the server while sharing from a device sitting still.
@MainActor
@Suite struct UploadThinningTests {
    @Test func aStillDeviceSendsOnlyTheFirstFixInsideTheHeartbeat() async {
        let me = UUID()
        let t = FakeTraxTransport()
        await t.setOutgoing([Fixtures.share(owner: me, viewer: UUID())])
        let sync = TraxSync(transport: t, store: TraxStore(inMemory: true), currentUserID: me)
        await sync.refreshOutgoing()
        let start = Date()
        for i in 0..<10 {   // a fix every 6 s over the last minute, all from the same spot
            sync.ingestFix(TraxFix(lat: 30, lng: -90, horizontalAccuracy: 5, motion: "stationary",
                                   timestamp: start.addingTimeInterval(-60 + Double(i) * 6)))
            for _ in 0..<20 { await Task.yield() }
        }
        #expect(await t.count("track") == 1)
    }
}

/// Geofence crossings detected before the kit subscribes (a cold launch by a
/// crossing) are handed over, not dropped.
@MainActor
@Suite struct TransitionBufferTests {
    func crossing(_ e: TraxEvent = .enter) -> TraxTransition {
        TraxTransition(placeID: UUID(), event: e, timestamp: Date())
    }

    @Test func crossingsBeforeSubscribingAreDelivered() async {
        let engine = TraxLocationEngine()
        let a = crossing(.enter), b = crossing(.leave)
        engine.deliver(a); engine.deliver(b)
        var got: [TraxTransition] = []
        for await t in engine.transitionStream() {
            got.append(t)
            if got.count == 2 { break }
        }
        #expect(got == [a, b])
    }

    @Test func crossingsAfterTheListenerLeavesWaitForTheNext() async {
        let engine = TraxLocationEngine()
        let listener = Task { for await _ in engine.transitionStream() {} }
        await Task.yield()
        listener.cancel()
        await listener.value
        for _ in 0..<10 { await Task.yield() }   // onTermination hops to the main actor
        let c = crossing()
        engine.deliver(c)
        var got: TraxTransition?
        for await t in engine.transitionStream() { got = t; break }
        #expect(got == c)
    }

    @Test func signOutForgetsUndeliveredCrossings() async {
        let engine = TraxLocationEngine()
        engine.deliver(crossing())
        engine.stop()
        let c = crossing()
        engine.deliver(c)
        var got: TraxTransition?
        for await t in engine.transitionStream() { got = t; break }
        #expect(got == c)   // only the crossing after sign-out
    }
}
