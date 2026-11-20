import SwiftUI

/// The whole TraxKit experience as one droppable view over the host-owned engine.
/// The host constructs the `TraxEngine` (with its `TraxConfig` + `TraxLocationHost`)
/// and drives `start()`/`stop()` from its session lifecycle; this view just renders
/// the hub and keeps the geofence regions reconciled. Every view reads values the
/// engine publishes; none reads SwiftData. `embedded`: the host owns the nav
/// chrome (its own header).
public struct TraxRootView: View {
    let engine: TraxEngine
    private let embedded: Bool
    private let onSignOut: (() -> Void)?
    private let appearance: TraxAppearance

    public init(engine: TraxEngine, embedded: Bool = false, onSignOut: (() -> Void)? = nil,
                appearance: TraxAppearance = .standard) {
        self.engine = engine
        self.embedded = embedded
        self.onSignOut = onSignOut
        self.appearance = appearance
    }

    public var body: some View {
        // No gate — the map is just there (watch-only) until you decide to share.
        // The host owns location + the auth prompt; the kit just renders.
        TraxHub(engine: engine, embedded: embedded, onSignOut: onSignOut, appearance: appearance)
            .background { RegionSyncer(engine: engine) }   // immediate region reconcile on place edits
    }
}

/// Invisible helper: when the user's places change, re-hand the regions to the host's
/// geofence right away (the engine's poll also refreshes them, slower).
struct RegionSyncer: View {
    let engine: TraxEngine

    /// The places' geometry: what the geofence cares about.
    private var signature: String {
        engine.sync.placeSnapshots.map { "\($0.id.uuidString):\($0.lat),\($0.lng),\($0.radiusM)" }
            .sorted().joined(separator: "|")
    }

    var body: some View {
        Color.clear.onChange(of: signature) { _, _ in engine.pushRegions() }
    }
}
