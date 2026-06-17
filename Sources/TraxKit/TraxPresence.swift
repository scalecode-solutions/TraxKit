import Foundation
import SwiftUI

// Member presence — the dense "status line" Life360 surfaces on every member
// (e.g. "Driving · 68 mph", "Last updated now", battery). Pure derivation from
// the telemetry already flowing on a ShareEntity (speed/motion/battery/recordedAt)
// — no new network. References Life360's member-status UX and Tangle's
// TangleHubPerson (label / sinceText / battery).

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
    public let isStale: Bool        // fix older than the stale threshold
    public let isLive: Bool         // fresh fix — show the live/online dot

    /// The one-line status, Life360-style: "Driving · 68 mph" or "Walking".
    public var line: String {
        if let mph = speedMph, activity == .driving || activity == .running {
            return "\(activity.label) · \(mph) mph"
        }
        return activity.label
    }

    /// Stale threshold — beyond this, we say the fix isn't updating.
    static let staleAfter: TimeInterval = 10 * 60
    /// Live threshold — a fix this fresh lights the "live/online" dot.
    static let liveWithin: TimeInterval = 2 * 60

    public static func make(speedMps: Double?, motion: String?, batteryLevel: Int?,
                            batteryCharging: Bool, recordedAtMs: Int64?, now: Date = Date()) -> TraxMemberStatus {
        let activity = activity(motion: motion, speedMps: speedMps)
        var mph: Int?
        if let s = speedMps, s > 0.5 { mph = Int((s * 2.23694).rounded()) }

        let battery = TraxBatteryStatus(level: batteryLevel, charging: batteryCharging)

        var lastUpdated = "—"
        var stale = false
        var live = false
        if let ms = recordedAtMs {
            let age = now.timeIntervalSince1970 - Double(ms) / 1000
            stale = age > staleAfter
            live = age <= liveWithin
            lastUpdated = stale ? "Not updating" : relative(age)
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
                              batteryCharging: batteryCharging ?? false, recordedAtMs: locRecordedAt, now: now)
    }
}
