import Foundation
import CoreLocation

/// Whether a device fix is worth uploading, given the last one delivered.
///
/// A pure decision on (last delivered fix, new fix, now), pinned by a truth
/// table in the tests. A phone sitting still used to post every five seconds;
/// most stored points said "still here". Now a fix goes out when it says
/// something new:
/// - nothing has been delivered yet;
/// - it moved at least `minMove` from the last delivered fix;
/// - the motion changed (walking → driving, or came to rest);
/// - `heartbeat` has passed, so a viewer still sees the sharer as live (the
///   live dot lasts two minutes from the last fix: `TraxMemberStatus.liveWithin`).
/// Never more often than `minInterval`, however fast the device moves.
enum UploadPolicy {
    static let minInterval: TimeInterval = 5
    static let minMove: CLLocationDistance = 25
    static let heartbeat: TimeInterval = 90

    enum Decision: Equatable { case post, skip }

    static func decide(last: TraxFix?, new: TraxFix, now: Date) -> Decision {
        guard let last else { return .post }
        let elapsed = now.timeIntervalSince(last.timestamp)
        if elapsed < minInterval { return .skip }
        if elapsed >= heartbeat { return .post }
        if let m = new.motion, m != last.motion { return .post }
        let moved = CLLocation(latitude: last.lat, longitude: last.lng)
            .distance(from: CLLocation(latitude: new.lat, longitude: new.lng))
        return moved >= minMove ? .post : .skip
    }
}
