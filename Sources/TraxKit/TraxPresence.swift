import Foundation
import SwiftUI

// Member presence — the dense "status line" Life360 surfaces on every member
// (e.g. "Driving · 68 mph", "Last updated now", battery). Pure derivation from
// the telemetry already flowing on a ShareEntity (speed/motion/battery/recordedAt)
// — no new network. References Life360's member-status UX (label / since-text / battery).

/// Coarse activity derived from motion class + speed.
public enum TraxActivity: Sendable {
    case stationary, walking, running, driving, moving, unknown

    var label: String {
        switch self {
        case .stationary: "Not moving"
        case .walking:    "Walking"
        case .running:    "Running"
        case .driving:    "Driving"
        case .moving:     "On the move"
        case .unknown:    "Location shared"
        }
    }
    var symbol: String {
        switch self {
        case .stationary: "figure.stand"
        case .walking:    "figure.walk"
        case .running:    "figure.run"
        case .driving:    "car.fill"
        case .moving:     "location.fill"
        case .unknown:    "mappin.circle"
        }
    }
}

/// Battery presentation (level + charging + a low flag for styling).
public struct TraxBatteryStatus: Sendable {
    public let level: Int?
    public let charging: Bool
    public var isLow: Bool { (level ?? 100) <= 20 }
    public var text: String? { level.map { "\($0)%" } }
}

/// A member's status, ready to render. Built from a ShareEntity at a given time.
public struct TraxMemberStatus: Sendable {
    public let activity: TraxActivity
    public let speedMph: Int?       // nil when not moving / unknown
    public let battery: TraxBatteryStatus
    public let lastUpdated: String  // "Just now", "3 min ago", "Not updating"
    public let isStale: Bool        // an update was expected and didn't come
    public let isLive: Bool         // fresh fix — show the live/online dot

    /// The one-line status, Life360-style: "Driving · 68 mph" or "Walking".
    public var line: String {
        if let mph = speedMph, activity == .driving || activity == .running {
            return "\(activity.label) · \(mph) mph"
        }
        return activity.label
    }

    /// Stale threshold — beyond this, an exact share isn't updating.
    static let staleAfter: TimeInterval = 10 * 60
    /// Live threshold — a fix this fresh lights the "live/online" dot.
    static let liveWithin: TimeInterval = 2 * 60

    /// "Not updating" means an update was expected and didn't come, not that the
    /// phone hasn't moved. Only an exact share is expected to update steadily
    /// (its sharer's phone sends a heartbeat even while still). A place or
    /// approximate share legitimately goes quiet for hours while the phone sits
    /// still, so its age is shown plainly and never called stale.
    public static func make(speedMps: Double?, motion: String?, batteryLevel: Int?,
                            batteryCharging: Bool, recordedAtMs: Int64?, precision: String = "exact",
                            now: Date = Date()) -> TraxMemberStatus {
        let activity = activity(motion: motion, speedMps: speedMps)
        var mph: Int?
        if let s = speedMps, s > 0.5 { mph = Int((s * 2.23694).rounded()) }

        let battery = TraxBatteryStatus(level: batteryLevel, charging: batteryCharging)

        var lastUpdated = "—"
        var stale = false
        var live = false
        if let ms = recordedAtMs {
            let age = now.timeIntervalSince1970 - Double(ms) / 1000
            let steady = precision == "exact"
            stale = steady && age > staleAfter
            live = age <= liveWithin
            // An approximate share's time is as coarse as its place, so it can't
            // be used to pin down when someone arrived somewhere.
            lastUpdated = stale ? "Not updating" : precision == "approx" ? coarseRelative(age) : relative(age)
        }
        return TraxMemberStatus(activity: activity, speedMph: mph, battery: battery,
                                lastUpdated: lastUpdated, isStale: stale, isLive: live)
    }

    private static func activity(motion: String?, speedMps: Double?) -> TraxActivity {
        switch motion {
        case "automotive": return .driving
        case "running":    return .running
        case "walking":    return .walking
        case "cycling":    return .moving
        case "stationary": return .stationary
        default: break
        }
        // No motion class — infer from speed.
        guard let s = speedMps else { return .unknown }
        if s < 0.5 { return .stationary }
        if s > 8   { return .driving }   // ~18 mph+
        if s > 2   { return .moving }
        return .walking
    }

    private static func coarseRelative(_ age: TimeInterval) -> String {
        if age < 3600 { return "Within the hour" }
        if age < 7200 { return "1 hr ago" }
        return "\(Int(age / 3600)) hr ago"
    }

    private static func relative(_ age: TimeInterval) -> String {
        if age < 45 { return "Just now" }
        if age < 90 { return "1 min ago" }
        if age < 3600 { return "\(Int(age / 60)) min ago" }
        if age < 7200 { return "1 hr ago" }
        return "\(Int(age / 3600)) hr ago"
    }
}

extension ShareEntity {
    /// This sharer's current status, evaluated now.
    func status(now: Date = Date()) -> TraxMemberStatus {
        TraxMemberStatus.make(speedMps: speed, motion: motion, batteryLevel: batteryLevel,
                              batteryCharging: batteryCharging ?? false, recordedAtMs: locRecordedAt,
                              precision: precision, now: now)
    }
}
