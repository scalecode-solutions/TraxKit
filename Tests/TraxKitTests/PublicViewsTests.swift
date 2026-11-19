import Foundation
import Testing
@testable import TraxKit

/// The logic under the public views (the views themselves run in TraxLab's UI
/// tests on a small phone at large text and on a large one).
@MainActor
@Suite struct PublicViewsTests {
    let me = UUID(), friend = UUID()

    func engine(_ t: FakeTraxTransport) -> TraxEngine {
        let config = TraxConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: me, tokenProvider: { nil })
        return TraxEngine(config: config, host: FakeTraxLocationHost(), transport: t, store: TraxStore(inMemory: true))
    }

    @Test func badgeDirectionFollowsTheRelationship() async {
        let t = FakeTraxTransport()
        let e = engine(t)
        #expect(TraxShareDirection(e.relationship(with: friend)) == nil)          // neither shares

        await t.setOutgoing([Fixtures.share(owner: me, viewer: friend)])
        await e.sync.refreshOutgoing()
        #expect(TraxShareDirection(e.relationship(with: friend)) == .iShare)

        await t.queueFeed(Fixtures.page([Fixtures.share(owner: friend, viewer: me, lat: 1, lng: 1)]))
        await e.sync.refresh()
        #expect(TraxShareDirection(e.relationship(with: friend)) == .both)

        await t.setOutgoing([])
        await e.sync.refreshOutgoing()
        #expect(TraxShareDirection(e.relationship(with: friend)) == .theyShare)
    }

    @Test func appearanceFillsInTheName() {
        let a = TraxAppearance(notSharing: "%@ is hidden")
        #expect(a.with(a.notSharing, "Sam") == "Sam is hidden")
        #expect(TraxAppearance.standard.with(TraxAppearance.standard.shareButton, "Sam") == "Share My Location with Sam")
    }
}

/// Changing a share keeps what the user didn't change.
@Suite struct DurationChoiceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func share(expiresIn seconds: TimeInterval?) -> TraxOutgoingShare {
        TraxOutgoingShare(ShareDTO(id: UUID(), ownerId: UUID(), viewerId: UUID(), mode: "live", retention: "none",
                                   precision: "exact", startedAt: 0,
                                   expiresAt: seconds.map { Int64((now.timeIntervalSince1970 + $0) * 1000) },
                                   location: nil, fuzzRadiusM: nil, placeName: nil, placeEmoji: nil, atPlace: nil))
    }

    @Test func changingAnUntilIStopShareKeepsItUntilIStop() {
        let s = share(expiresIn: nil)
        let choice = DurationChoice.initial(for: s)
        #expect(choice == .preset(.indefinite))
        #expect(choice.duration(current: s, now: now) == nil)
        #expect(!DurationChoice.options(changing: s).contains(.keepCurrent))
    }

    @Test func changingATimedShareKeepsItsEnd() {
        let s = share(expiresIn: 40 * 60)
        let choice = DurationChoice.initial(for: s)
        #expect(choice == .keepCurrent)
        #expect(choice.duration(current: s, now: now) == .seconds(40 * 60))
        #expect(DurationChoice.options(changing: s).first == .keepCurrent)
    }

    @Test func aShareAboutToEndIsSentAtLeastAMinute() {
        let s = share(expiresIn: 5)
        #expect(DurationChoice.keepCurrent.duration(current: s, now: now) == .seconds(60))
    }

    @Test func presetsSendTheirLength() {
        #expect(DurationChoice.preset(.oneHour).duration(current: nil, now: now) == .seconds(3600))
        #expect(DurationChoice.preset(.indefinite).duration(current: nil, now: now) == nil)
    }
}
