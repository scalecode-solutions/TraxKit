import Foundation
import CoreLocation
import MapKit
import Testing
@testable import TraxKit

/// The hub's derived people are rebuilt only when their inputs change, not on
/// every render (a sheet drag renders every frame).
@MainActor
@Suite struct HubMemoTests {
    func key(lat: Double? = 30, clock: Int = 1, names: [String] = ["You", "A"]) -> HubPeopleMemo.Key {
        HubPeopleMemo.Key(incoming: [], contacts: [TraxContact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "A", avatar: nil)],
                          places: [], names: names, fixLat: lat, fixLng: -90, battery: 80, charging: false, clock: clock)
    }

    @Test func sameInputsBuildOnce() {
        let memo = HubPeopleMemo()
        for _ in 0..<10 { _ = memo.value(for: key()) { (nil, []) } }
        #expect(memo.builds == 1)
    }

    @Test func changedInputsRebuild() {
        let memo = HubPeopleMemo()
        _ = memo.value(for: key()) { (nil, []) }
        _ = memo.value(for: key(lat: 30.001)) { (nil, []) }   // I moved
        _ = memo.value(for: key(lat: 30.001, clock: 2)) { (nil, []) }   // statuses aged
        #expect(memo.builds == 3)
    }

    /// A host renaming someone (a new nickname) changes nothing in the engine,
    /// so the names themselves are part of the key.
    @Test func aHostNameChangeRebuilds() {
        let memo = HubPeopleMemo()
        _ = memo.value(for: key(names: ["You", "A"])) { (nil, []) }
        _ = memo.value(for: key(names: ["You", "A"])) { (nil, []) }
        _ = memo.value(for: key(names: ["You", "Sunny"])) { (nil, []) }
        #expect(memo.builds == 2)
    }
}

@Suite struct AvatarInitialsTests {
    @Test(arguments: [
        ("Ada Byron King", "AK"),   // first + last, the middle name doesn't count
        ("ada lovelace", "AL"),
        ("Ada", "A"),
        ("  Ada   Lovelace  ", "AL"),
        ("", "?"),
    ])
    func initials(_ name: String, _ want: String) {
        #expect(TraxAvatar.initials(name) == want)
    }

    @Test func noName() { #expect(TraxAvatar.initials(nil) == "?") }
}

@MainActor
@Suite struct HubFramingTests {
    @Test func fitsEveryoneWithMargin() throws {
        let me = CLLocationCoordinate2D(latitude: 37.32, longitude: -122.03)
        let friend = CLLocationCoordinate2D(latitude: 37.40, longitude: -121.90)
        let r = try #require(TraxHub.fitting([me, friend]))
        for c in [me, friend] {
            #expect(abs(c.latitude - r.center.latitude) < r.span.latitudeDelta / 2)
            #expect(abs(c.longitude - r.center.longitude) < r.span.longitudeDelta / 2)
        }
    }

    @Test func oneOrNone() {
        #expect(TraxHub.fitting([]) == nil)
        let r = TraxHub.fitting([CLLocationCoordinate2D(latitude: 30, longitude: -90)])
        #expect(r?.span.latitudeDelta == 0.02, "a lone person still gets a street-level frame")
    }
}

@Suite struct HubDetentScalingTests {
    @Test func rowsGrowWithTextAndNeverExceedTheScreen() {
        let base = HubDetent.mid.height(available: 800, rowCount: 3)
        let big = HubDetent.mid.height(available: 800, rowCount: 3, scale: 2)
        #expect(big > base, "larger text, taller rows")
        #expect(HubDetent.mid.height(available: 800, rowCount: 3, scale: 4) == 800, "capped at the space there is")
        #expect(HubDetent.peek.height(available: 800, rowCount: 3, scale: 1) == HubMetrics.header + 8)
    }
}
