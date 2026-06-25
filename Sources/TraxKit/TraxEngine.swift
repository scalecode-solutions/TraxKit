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

    public init(config: TraxConfig, host: any TraxLocationHost) {
        let store = TraxStore(userID: config.currentUserID, appGroup: config.appGroup)
        self.store = store
        self.host = host
        self.sync = TraxSync(config: config, store: store)
        self.bridge = TraxLocationStore(sync: sync, store: store)
        self.weather = TraxWeatherStore(provider: config.weatherProvider ?? WeatherKitProvider())
        self.geocoder = TraxGeocoder()
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
        // host device fixes → the observable self-fix + the share-gated, throttled poster.
        currentFix = host.currentFix
        fixTask = Task { [weak self] in
            guard let self else { return }
            for await fix in self.host.fixStream() {
                self.currentFix = fix
                self.sync.ingestFix(fix)
            }
        }
        // host geofence crossings → record + post + fan out.
        transitionTask = Task { [weak self] in
            guard let self else { return }
            for await t in self.host.transitionStream() {
                await self.sync.postTransition(placeID: t.placeID, event: t.event.rawValue)
            }
        }
        pollTask = Task { [weak self] in await self?.poll() }
    }

    public func stop() {
        pollTask?.cancel(); fixTask?.cancel(); transitionTask?.cancel()
        pollTask = nil; fixTask = nil; transitionTask = nil
        host.setDesiredTracking(.off)
        host.setMonitoredRegions([])
    }

    // MARK: - Poll + seam push

    private func poll() async {
        await sync.loadContacts()
        await sync.loadPlaces()
        await sync.refresh()
        await sync.refreshOutgoing()
        pushRegions()
        pushDemand()
        observeOutgoing()
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            if Task.isCancelled { break }
            await sync.refresh()
            await sync.refreshOutgoing()
            tick += 1
            if tick % 6 == 0 { await sync.loadPlaces(); pushRegions() }   // ~2 min: refresh places + regions
            pushDemand()
        }
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
