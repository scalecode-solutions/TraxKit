import SwiftUI
import SwiftData

/// The whole TraxKit experience as one droppable view — the standalone app.
/// TraxLab renders this; Clingy can later embed it wholesale OR weave the
/// composable pieces (`TraxMapView`, `TraxPlacesView`, `TraxSettingsView`) into
/// its own chrome. Owns the single sync engine, the location producer, and the
/// poll loop; injects the SwiftData container into the whole tree.
///
/// (Tab scaffold for now — every feature lands in its real home. The Map tab can
/// evolve into a Life360-style map + member carousel without disturbing the rest.)
public struct TraxRootView: View {
    /// The shared, app-wide sync — owns the feed, the data, and the chat bridge.
    /// Injected by the host so ONE instance backs both the Trax tab and Clingy's
    /// chat threads (the arrival/"left" bridge stays live with the tab off-screen).
    let sync: TraxSync
    private let onSignOut: (() -> Void)?
    /// When true, the host owns the nav chrome (NavigationStack + leading title);
    /// TraxHub drops its own so a host (Clingy) can wrap it with a back-to-cover header.
    private let embedded: Bool
    @State private var weather: TraxWeatherStore
    @State private var selfState = TraxSelfState()
    @State private var geocoder = TraxGeocoder()
    @State private var permissions: TraxPermissions

    /// The view owns only the device-side, tab-scoped pieces (producer, geofence,
    /// self dot, weather, permissions); the shared `sync` is injected by the host.
    /// `onSignOut`, when provided, surfaces a Sign Out control in the Me tab.
    public init(sync: TraxSync, embedded: Bool = false,
                onSignOut: (() -> Void)? = nil,
                onSystemDialog: (@MainActor (Bool) -> Void)? = nil) {
        self.sync = sync
        self.onSignOut = onSignOut
        self.embedded = embedded
        _permissions = State(initialValue: TraxPermissions(onSystemDialog: onSystemDialog))
        _weather = State(initialValue: TraxWeatherStore(provider: WeatherKitProvider()))
    }

    public var body: some View {
        // No gate, no forced choice — the map is just there, watch-only, until you
        // decide to share. Permission rides the Share action, the way Tangle did it.
        hub
    }

    private var hub: some View {
        TraxHub(sync: sync, weather: weather, selfState: selfState, geocoder: geocoder, permissions: permissions, embedded: embedded, onSignOut: onSignOut)
            .modelContainer(sync.container)
            .task { await runLoop() }
            .onDisappear { selfState.stop() }
    }

    /// Keep the feed + outgoing shares + my places fresh on a snappy 5s poll while
    /// the tab is visible (the app-wide engine also polls, slower; TraxSync de-dupes
    /// concurrent refreshes). The producer lifecycle is the engine's job now, so MY
    /// location keeps broadcasting when this tab is off-screen.
    private func runLoop() async {
        selfState.start()
        await sync.loadContacts()
        await sync.loadPlaces()
        await sync.refresh()
        await sync.refreshOutgoing()
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { break }
            await sync.refresh()
            await sync.refreshOutgoing()
            tick += 1
            if tick % 6 == 0 { await sync.loadPlaces() }   // ~30s: pick up places others shared with me
        }
    }
}
