import Foundation
import Observation
import SwiftData

/// The coordinator — TraxKit's embed root. The host constructs ONE per signed-in
/// session (a `TraxConfig` + a `TraxLocationHost` device engine), then drives
/// `start()`/`stop()` from its session lifecycle. The engine owns the store + sync
/// + bridge, wires the host seam both ways, and runs the app-wide feed poll. The UI
/// (`TraxRootView`) renders from it; chat reads `bridge`.
///
/// Cold-launch contract: the host wakes on a geofence crossing and calls `start()`;
/// the transition stream then delivers the crossing and the kit records + posts it.
@MainActor
@Observable
public final class TraxEngine {
    public let sync: TraxSync
    public let bridge: TraxLocationStore
    public let weather: TraxWeatherStore
    public let geocoder: TraxGeocoder

    private let store: TraxStore
    private let host: any TraxLocationHost

    private var pollTask: Task<Void, Never>?
    private var fixTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?

    public convenience init(config: TraxConfig, host: any TraxLocationHost) {
        self.init(config: config, host: host, transport: config.transport,
                  store: TraxStore(userID: config.currentUserID, appGroup: config.appGroup,
                                   directory: config.storeDirectory))
    }

    /// The seam tests use: any transport, any store.
    init(config: TraxConfig, host: any TraxLocationHost, transport: any TraxTransport, store: TraxStore) {
        self.store = store
        self.host = host
        self.sync = TraxSync(transport: transport, store: store, currentUserID: config.currentUserID)
        self.bridge = TraxLocationStore(sync: sync, store: store)
        self.weather = TraxWeatherStore(provider: config.weatherProvider ?? WeatherKitProvider())
        self.geocoder = TraxGeocoder()
    }

    /// A host that drops its engine without calling `stop()` doesn't leak it:
    /// the tasks below never hold the engine between steps, so it can deinit,
    /// and deinit ends them.
    isolated deinit {
        pollTask?.cancel(); fixTask?.cancel(); transitionTask?.cancel()
    }

    // MARK: - Location-facing API (replaces TraxSelfState / TraxPermissions)

    /// The host's latest fix — the map's self-dot + the place editor's "use current
    /// location". Stored + @Observable (fed from the fix stream) so the UI reacts.
    public private(set) var currentFix: TraxFix?
    public var authorization: TraxLocationAuth { host.authorization }
    public func requestLocationAccess() { host.requestLocationAccess() }

    // MARK: - Lifecycle (the host drives this from its session)

    public func start() {
        guard pollTask == nil else { return }
        sync.resume()
        // host device fixes → the observable self-fix + the share-gated, throttled poster.
        // Each task re-takes `self` per step, so it never keeps the engine alive.
        currentFix = host.currentFix
        let fixes = host.fixStream()
        fixTask = Task { [weak self] in
            for await fix in fixes {
                guard let self else { return }
                self.currentFix = fix
                self.sync.ingestFix(fix)
            }
        }
        // host geofence crossings → record + post + fan out.
        let crossings = host.transitionStream()
        transitionTask = Task { [weak self] in
            for await t in crossings {
                guard let self else { return }
                await self.sync.postTransition(placeID: t.placeID, event: t.event.rawValue)
            }
        }
        pollTask = Task { [weak self] in
            await self?.pollFirst()
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self else { return }
                tick += 1
                await self.pollTick(tick)
            }
        }
    }

    /// Stop polling and posting. Work already in flight finishes without
    /// writing anything (the sync layer drops results from before the stop).
    public func stop() {
        sync.invalidate()
        pollTask?.cancel(); fixTask?.cancel(); transitionTask?.cancel()
        pollTask = nil; fixTask = nil; transitionTask = nil
        host.setDesiredTracking(.off)
        host.setMonitoredRegions([])
    }

    /// Sign-out wipe: clear all persisted Trax data (shares, contacts, places,
    /// transitions, cursor) and the in-memory state through the live store
    /// context — the SwiftData-sanctioned way (see `TraxStore.wipeAll`). Call it
    /// while the container is still open (before dropping the engine). Anything
    /// in flight when it runs is discarded rather than written back, and nothing
    /// is written again until the next `start()`.
    public func wipeStore() {
        sync.wipe()
    }

    // MARK: - Poll + seam push

    private func pollFirst() async {
        await sync.loadContacts()
        await sync.loadPlaces()
        await sync.refresh()
        await sync.refreshOutgoing()
        pushRegions()
        pushDemand()
        observeOutgoing()
    }

    private func pollTick(_ tick: Int) async {
        sync.flushPendingTrack()   // a fix whose post failed goes out even if no new fix arrives
        await sync.refresh()
        await sync.refreshOutgoing()
        if tick % 6 == 0 { await sync.loadPlaces(); pushRegions() }   // ~2 min: refresh places + regions
        pushDemand()
    }

    /// Re-hand the kit's place-regions to the host's geofence (its rolling-20 merges
    /// them). Call after a place edit for an immediate update; the poll also refreshes.
    public func pushRegions() {
        host.setMonitoredRegions(store.allPlaces().map {
            TraxRegion(placeID: $0.id, lat: $0.lat, lng: $0.lng, radiusMeters: Double($0.radiusM))
        })
    }

    private func pushDemand() { host.setDesiredTracking(sync.trackingDemand) }

    /// React to share start/stop immediately → update the host's tracking demand.
    private func observeOutgoing() {
        withObservationTracking { _ = sync.outgoing } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.pollTask != nil else { return }
                self.pushDemand()
                self.observeOutgoing()
            }
        }
    }
}
