import Foundation

// The producer's and viewer's lifetime rules as pure functions: no I/O, no
// state, every input explicit, so each is pinned by a truth table
// (PolicyTests). Unknown or missing inputs resolve to the quietest choice.

/// How hard the device should track, from the precision of my live shares.
///
/// The share's precision is the user's choice of how much to reveal, so it is
/// also the choice of how hard to track (MVTRAX-18 step 10, decided 2026-11-19):
/// - exact: full rate, in the foreground and the background, however long the
///   share lasts. Choosing exact is the opt-in.
/// - place: coarse while the app is open; significant-change in the background
///   (the place fences report arrivals on their own).
/// - approx: ~1 km while open; significant-change in the background.
/// The most precise live share sets the tier. No share or no permission → off.
enum TrackingDemandPolicy {
    static func demand(precisions: Set<TraxPrecision>, auth: TraxLocationAuth,
                       foreground: Bool) -> TraxTrackingDemand {
        switch auth {
        case .always, .whenInUse: break
        case .notDetermined, .denied: return .off
        }
        if precisions.contains(.exact) { return .continuous }
        if precisions.contains(.place) { return foreground ? .coarse : .significant }
        if precisions.contains(.approx) { return foreground ? .approximate : .significant }
        return .off
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
