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
