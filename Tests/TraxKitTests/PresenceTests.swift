import Foundation
import Testing
@testable import TraxKit

/// What a viewer reads about a sharer's freshness, per precision and age.
/// "Not updating" means an expected update didn't come: only an exact share
/// promises steady updates (its phone keeps sending while still).
@Suite struct PresenceTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    struct Row: CustomTestStringConvertible, Sendable {
        let precision: String
        let ageMinutes: Double
        let text: String
        let stale: Bool
        let live: Bool
        var testDescription: String { "\(precision), \(ageMinutes) min" }
    }

    static let rows: [Row] = [
        Row(precision: "exact",  ageMinutes: 0.5, text: "Just now",        stale: false, live: true),
        Row(precision: "exact",  ageMinutes: 5,   text: "5 min ago",       stale: false, live: false),
        Row(precision: "exact",  ageMinutes: 11,  text: "Not updating",    stale: true,  live: false),
        Row(precision: "exact",  ageMinutes: 180, text: "Not updating",    stale: true,  live: false),
        Row(precision: "place",  ageMinutes: 11,  text: "11 min ago",      stale: false, live: false),
        Row(precision: "place",  ageMinutes: 180, text: "3 hr ago",        stale: false, live: false),
        Row(precision: "approx", ageMinutes: 0.5, text: "Within the hour", stale: false, live: true),
        Row(precision: "approx", ageMinutes: 42,  text: "Within the hour", stale: false, live: false),
        Row(precision: "approx", ageMinutes: 180, text: "3 hr ago",        stale: false, live: false),
    ]

    @Test(arguments: rows) func freshness(_ r: Row) {
        let ms = Int64((Self.now.timeIntervalSince1970 - r.ageMinutes * 60) * 1000)
        let st = TraxMemberStatus.make(speedMps: nil, motion: nil, batteryLevel: nil, batteryCharging: false,
                                       recordedAtMs: ms, precision: r.precision, now: Self.now)
        #expect(st.lastUpdated == r.text)
        #expect(st.isStale == r.stale)
        #expect(st.isLive == r.live)
    }
}
