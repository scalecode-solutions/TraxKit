import SwiftUI
import SwiftData

/// The whole TraxKit experience as one droppable view over the host-owned engine.
/// The host constructs the `TraxEngine` (with its `TraxConfig` + `TraxLocationHost`)
/// and drives `start()`/`stop()` from its session lifecycle; this view just renders
/// the hub, injects the SwiftData container, and keeps the geofence regions
/// reconciled. `embedded`: the host owns the nav chrome (back-to-cover header).
public struct TraxRootView: View {
    let engine: TraxEngine
    private let embedded: Bool
    private let onSignOut: (() -> Void)?

    public init(engine: TraxEngine, embedded: Bool = false, onSignOut: (() -> Void)? = nil) {
        self.engine = engine
        self.embedded = embedded
        self.onSignOut = onSignOut
    }

    public var body: some View {
        // No gate — the map is just there (watch-only) until you decide to share.
        // The host owns location + the auth prompt; the kit just renders.
        TraxHub(engine: engine, embedded: embedded, onSignOut: onSignOut)
            .modelContainer(engine.sync.container)
            .background { RegionSyncer(engine: engine) }   // immediate region reconcile on place edits
    }
}

/// Invisible helper: when the user's places change, re-hand the regions to the host's
/// geofence right away (the engine's poll also refreshes them, slower). Lives inside
/// the modelContainer so its `@Query` resolves.
private struct RegionSyncer: View {
    let engine: TraxEngine
    @Query private var places: [PlaceEntity]

    /// @Model isn't Equatable, so onChange keys on a geometry signature.
    private var signature: String {
        places.map { "\($0.id.uuidString):\($0.lat),\($0.lng),\($0.radiusM)" }.sorted().joined(separator: "|")
    }

    var body: some View {
        Color.clear.onChange(of: signature) { _, _ in engine.pushRegions() }
    }
}
