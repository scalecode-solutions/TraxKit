import Testing
import Foundation
@testable import TraxKit

@Suite struct DTOTests {

    /// The feed wire shape: shares with a nested current-location head + cursor.
    @Test func decodesFeedPage() throws {
        let json = """
        {
          "shares": [{
            "id": "11111111-1111-4111-8111-111111111111",
            "ownerId": "22222222-2222-4222-8222-222222222222",
            "viewerId": "33333333-3333-4333-8333-333333333333",
            "mode": "live",
            "retention": "indefinite",
            "startedAt": 1000,
            "expiresAt": null,
            "location": { "lat": 40.1, "lng": -88.2, "batteryLevel": 88, "recordedAt": 2000 }
          }],
          "syncTs": 3000,
          "hasMore": false,
          "stoppedIds": []
        }
        """.data(using: .utf8)!

        let feed = try JSONDecoder().decode(FeedDTO.self, from: json)
        #expect(feed.shares.count == 1)
        #expect(feed.syncTs == 3000)
        #expect(feed.hasMore == false)

        let share = try #require(feed.shares.first)
        #expect(share.mode == "live")
        #expect(share.expiresAt == nil)
        #expect(share.location?.lat == 40.1)
        #expect(share.location?.batteryLevel == 88)
        #expect(share.location?.recordedAt == 2000)
    }

    /// A breadcrumb point flattens the location fields onto the row.
    @Test func decodesFlatPoint() throws {
        let json = """
        { "id": "44444444-4444-4444-8444-444444444444", "lat": 1.5, "lng": 2.5, "recordedAt": 9 }
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(PointDTO.self, from: json)
        #expect(p.lat == 1.5)
        #expect(p.recordedAt == 9)
        #expect(p.accuracy == nil)
    }

    /// The start-share body encodes the keys mvTrax expects.
    @Test func encodesStartShareBody() throws {
        let body = StartShareBody(viewer: UUID(), mode: "live", retention: "indefinite", expiresIn: 900)
        let data = try JSONEncoder().encode(body)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["mode"] as? String == "live")
        #expect(obj["expiresIn"] as? Int == 900)
        #expect(obj["viewer"] != nil)
    }
}
