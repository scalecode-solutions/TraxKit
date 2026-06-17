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
    private let store: TraxStore
    private let onSignOut: (() -> Void)?
    @State private var sync: TraxSync
    @State private var producer: TraxLocationProducer
    @State private var geofence: TraxGeofenceMonitor
    @State private var weather: TraxWeatherStore
    @State private var selfState = TraxSelfState()
    @State private var geocoder = TraxGeocoder()
    @State private var permissions = TraxPermissions()

    /// `onSignOut`, when provided, surfaces a Sign Out control in the Me tab. The
    /// host owns the auth action; the SPM owns the chrome.
    public init(config: TraxConfig, store: TraxStore, onSignOut: (() -> Void)? = nil) {
        self.store = store
        self.onSignOut = onSignOut
        let s = TraxSync(config: config, store: store)
        _sync = State(initialValue: s)
        _producer = State(initialValue: TraxLocationProducer { body in
            try? await s.track(body)
        })
        _geofence = State(initialValue: TraxGeofenceMonitor { placeID, event in
            await s.postTransition(placeID: placeID, event: event)
        })
        _weather = State(initialValue: TraxWeatherStore(provider: config.weatherProvider ?? WeatherKitProvider()))
    }

    public var body: some View {
        if permissions.isAuthorized {
            hub
        } else {
            TraxOnboardingView(permissions: permissions)   // front door until location is granted
        }
    }

    private var hub: some View {
        TraxHub(sync: sync, weather: weather, selfState: selfState, geocoder: geocoder, onSignOut: onSignOut)
            .modelContainer(store.container)
            .background { GeofenceSyncer(monitor: geofence, selfState: selfState) }   // keeps nearest-20 regions in sync
            .task { await runLoop() }
            .onDisappear { producer.stop(); geofence.stopAll(); selfState.stop() }
    }

    /// Start producing, then keep the feed + outgoing shares + my places fresh on
    /// a 5s poll. `.task` cancels when the root disappears.
    private func runLoop() async {
        producer.start()
        selfState.start()
        await sync.loadContacts()
        await sync.loadPlaces()
        await sync.refresh()
        await sync.refreshOutgoing()
        producer.hasWatchers = !sync.outgoing.isEmpty   // watcher-aware cadence
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { break }
            await sync.refresh()
            await sync.refreshOutgoing()
            producer.hasWatchers = !sync.outgoing.isEmpty
            tick += 1
            if tick % 6 == 0 { await sync.loadPlaces() }   // ~30s: pick up places others shared with me
        }
    }
}

/// Invisible helper: watches the user's places and keeps the geofence monitor's
/// regions reconciled. Lives inside the modelContainer so its @Query resolves.
private struct GeofenceSyncer: View {
    let monitor: TraxGeofenceMonitor
    let selfState: TraxSelfState
    @Query private var places: [PlaceEntity]

    /// @Model isn't Equatable, so onChange keys on a geometry signature that
    /// captures adds/removes/center/radius edits.
    private var signature: String {
        places.map { "\($0.id.uuidString):\($0.lat),\($0.lng),\($0.radiusM)" }.sorted().joined(separator: "|")
    }

    /// ~1km bucket of the user's position — re-rotate the nearest-20 set when they
    /// travel into a new bucket (not on every fix).
    private var coordBucket: String {
        guard let c = selfState.coordinate else { return "" }
        return "\(Int(c.latitude * 100)),\(Int(c.longitude * 100))"
    }

    private func resync() { monitor.sync(places: places, around: selfState.coordinate) }

    var body: some View {
        Color.clear
            .onAppear { resync() }
            .onChange(of: signature) { _, _ in resync() }
            .onChange(of: coordBucket) { _, _ in resync() }
    }
}
