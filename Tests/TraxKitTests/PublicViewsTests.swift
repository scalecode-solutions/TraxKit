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

    @Test func badgeGlyphsAreDistinctAndHostCanReplaceThem() {
        let std = TraxShareGlyphs.standard
        #expect(Set([std.outgoing, std.incoming, std.both]).count == 3)
        #expect(std.glyph(for: .iShare) == std.outgoing)
        #expect(std.glyph(for: .theyShare) == std.incoming)
        #expect(std.glyph(for: .both) == std.both)

        let host = TraxShareGlyphs(outgoing: .asset("share.out"), incoming: .asset("share.in"),
                                   both: .system("circle"))
        #expect(host.glyph(for: .iShare) == .asset("share.out"))
        #expect(host.glyph(for: .theyShare) == .asset("share.in"))
        #expect(host.glyph(for: .both) == .system("circle"))
    }

    @Test func badgeScalingIsCapped() {
        let e = engine(FakeTraxTransport())
        #expect(TraxShareBadge(engine: e, otherID: friend, size: 12).maxSize == 18)
        #expect(TraxShareBadge(engine: e, otherID: friend, size: 12, maxSize: 16).maxSize == 16)
        // A cap below the base size never shrinks the badge.
        #expect(TraxShareBadge(engine: e, otherID: friend, size: 12, maxSize: 8).maxSize == 12)
    }

    @Test func settingsSplitMyPlacesFromOnesSharedWithMe() async {
        let t = FakeTraxTransport()
        let e = engine(t)
        let other = UUID()
        await t.setContacts([TraxContact(id: friend, name: "Friend")])
        await e.sync.loadContacts()
        await t.setPlaces([
            Fixtures.place(owner: me, name: "Mine", lat: 30, lng: -90),
            Fixtures.place(owner: me, name: "Ours", lat: 30, lng: -90, sharedWith: [friend, other]),
            Fixtures.place(owner: friend, name: "Theirs", lat: 30, lng: -90),
        ])
        await e.sync.loadPlaces()
        let byName = Dictionary(uniqueKeysWithValues: e.places.map { ($0.name, $0) })
        let names = TraxDisplayNames { $0 == friend ? "Nick" : nil }
        let name: (UUID) -> String = { names.name(for: $0, people: e.people) }

        #expect(traxPlaceSubtitle(byName["Mine"]!, name: name) == "Custom")
        #expect(traxPlaceSubtitle(byName["Ours"]!, name: name)
                == "Shared with Nick, Member \(other.uuidString.prefix(8))")
        #expect(traxPlaceSubtitle(byName["Theirs"]!, name: name) == "Shared by Nick")
        #expect(byName["Theirs"]?.isMine == false)
    }

    @Test func placeEditorAccessFollowsTheServerRule() {
        #expect(PlaceEditorAccess(isNew: true, ownerID: nil, me: me) == .full)
        #expect(PlaceEditorAccess(isNew: false, ownerID: me, me: me) == .full)
        #expect(PlaceEditorAccess(isNew: false, ownerID: friend, me: me) == .member)
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

    /// The share ended while "Keep current end" was chosen: the default
    /// length goes out, not an until-I-stop share nobody chose.
    @Test func keepingTheEndOfAShareThatEndedSendsTheDefault() {
        #expect(DurationChoice.keepCurrent.duration(current: nil, now: now) == .seconds(15 * 60))
        #expect(DurationChoice.keepCurrent.duration(current: share(expiresIn: nil), now: now) == .seconds(15 * 60))
    }

    @Test func presetsSendTheirLength() {
        #expect(DurationChoice.preset(.oneHour).duration(current: nil, now: now) == .seconds(3600))
        #expect(DurationChoice.preset(.indefinite).duration(current: nil, now: now) == nil)
    }
}
