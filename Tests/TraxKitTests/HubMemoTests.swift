import Foundation
import Testing
@testable import TraxKit

/// The hub's derived people are rebuilt only when their inputs change, not on
/// every render (a sheet drag renders every frame).
@MainActor
@Suite struct HubMemoTests {
    func key(lat: Double? = 30, clock: Int = 1) -> HubPeopleMemo.Key {
        HubPeopleMemo.Key(incoming: [], contacts: [TraxContact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "A", avatar: nil)],
                          places: [], fixLat: lat, fixLng: -90, battery: 80, charging: false, clock: clock)
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
}
