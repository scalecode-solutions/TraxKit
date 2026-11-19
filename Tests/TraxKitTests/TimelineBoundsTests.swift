import Foundation
import Testing
@testable import TraxKit

@MainActor
@Suite struct TimelineBoundsTests {
    /// A day's timeline asks the server for that day only: trips and visits
    /// starting in [start of day, start of next day). Without the upper bound a
    /// past day's rows were crowded out of the limit by everything since.
    @Test func dayReadsAreBoundedToTheDay() async {
        let t = FakeTraxTransport()
        let sync = TraxSync(transport: t, store: TraxStore(inMemory: true), currentUserID: UUID())
        let day = Date(timeIntervalSinceNow: -5 * 86_400)
        _ = await sync.timeline(ownerID: UUID(), day: day)

        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let startMs = Int64(start.timeIntervalSince1970 * 1000), endMs = Int64(end.timeIntervalSince1970 * 1000)
        let bounds = await t.timelineBounds
        #expect(bounds.count == 2)   // trips and visits
        for b in bounds {
            #expect(b.since == startMs)
            #expect(b.before == endMs)
        }
    }
}
