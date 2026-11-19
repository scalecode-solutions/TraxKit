import Foundation

// The producer's and viewer's lifetime rules as pure functions: no I/O, no
// state, every input explicit, so each is pinned by a truth table
// (PolicyTests). Unknown or missing inputs resolve to the quietest choice.

/// How hard the device should track, from what the user is doing.
enum TrackingDemandPolicy {
    /// - sharing: I have at least one live share (see ShareLivenessPolicy).
    /// - backgroundOptIn: continuous tracking in the background. Off until the
    ///   product decides it (MVTRAX-18 step 10); while off, sharing in the
    ///   background runs on significant-change only, which under When-In-Use
    ///   delivers nothing in the background. That is the intended quiet
    ///   default, not a bug.
    static func demand(sharing: Bool, auth: TraxLocationAuth, foreground: Bool,
                       backgroundOptIn: Bool = false) -> TraxTrackingDemand {
        guard sharing else { return .off }
        switch auth {
        case .always, .whenInUse: break
        case .notDetermined, .denied: return .off
        }
        if foreground { return .continuous }
        return backgroundOptIn ? .continuous : .significant
    }
}

/// Whether a fix may be posted at all.
enum ShareLivenessPolicy {
    /// - outgoingExpiries: my outgoing shares' expiry (epoch ms; nil = until I stop).
    /// - activeSharesInLastAck: the owner's active-share count the server
    ///   returned with the last delivered fix (TrackResponse.shares; not
    ///   "watchers"). nil before any delivery.
    /// - ackNewerThanOutgoing: that ack arrived after the outgoing list was last
    ///   refreshed (so it's the fresher word on whether shares exist).
    static func shouldPost(outgoingExpiries: [Int64?], activeSharesInLastAck: Int?,
                           ackNewerThanOutgoing: Bool, now: Date) -> Bool {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let live = outgoingExpiries.contains { $0 == nil || $0! > nowMs }
        guard live else { return false }
        if ackNewerThanOutgoing, activeSharesInLastAck == 0 { return false }   // stopped elsewhere
        return true
    }
}

/// How often the viewer's feed is polled.
enum FeedCadencePolicy {
    static let held: Duration = .seconds(5)
    static let foregroundUnheld: Duration = .seconds(30)

    /// nil = don't poll (the app is in the background; sharing doesn't depend
    /// on the poll: liveness comes from the fix acks and local expiry).
    static func interval(holds: Int, foreground: Bool) -> Duration? {
        guard foreground else { return nil }
        return holds > 0 ? held : foregroundUnheld
    }
}
