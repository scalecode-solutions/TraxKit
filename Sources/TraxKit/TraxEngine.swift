import Foundation
import Observation
import SwiftData

/// The coordinator — TraxKit's embed root. The host constructs ONE per signed-in
/// session (a `TraxConfig` + a `TraxLocationHost` device engine), then drives
/// `start()`/`stop()` from its session lifecycle. The engine owns the store + sync
/// + bridge, wires the host seam both ways, and runs the app-wide feed poll. The UI
/// (`TraxRootView`) renders from it; hosts read and act through its public API
/// (TraxEngine+API.swift).
///
/// Cold-launch contract: the host wakes on a geofence crossing and calls `start()`;
/// the transition stream then delivers the crossing and the kit records + posts it.
@MainActor
@Observable
public final class TraxEngine {
    let sync: TraxSync
    let bridge: TraxLocationStore
    public let weather: TraxWeatherStore
    public let geocoder: TraxGeocoder

    private let store: TraxStore
    private let host: any TraxLocationHost

    private var pollTask: Task<Void, Never>?
    private var fixTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
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
        nap?.cancel()
        pollTask?.cancel(); fixTask?.cancel(); transitionTask?.cancel(); expiryTask?.cancel()
        guard pollTask != nil else { return }   // never started, or already stopped
        host.setDesiredTracking(.off)           // don't leave the device tracking for nobody
        host.setMonitoredRegions([])
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
            while !Task.isCancelled {
                // The nap is taken without holding the engine, so a dropped
                // engine can still deinit while the poll sleeps.
                guard let nap = self?.nextNap() else { return }
                await nap.value
                guard !Task.isCancelled, let self else { return }
                await self.pollTick()
            }
        }
    }

    // MARK: - Holds (how fresh the feed must be)

    /// A screen showing others' locations appeared: refresh now, and poll at the
    /// held cadence while any screen holds the engine. Counted, so several
    /// screens can't fight. Sharing my own location doesn't depend on holds.
    public func acquire() {
        holders += 1
        wake()
    }

    /// That screen went away.
    public func release() {
        holders = max(0, holders - 1)
    }

    /// The app went to the background (false) or came back (true); coming back
    /// refreshes at once.
    public func setForeground(_ on: Bool) {
        let cameBack = on && !foreground
        foreground = on
        if pollTask != nil { pushDemand() }   // the tier can change with the app state (see TrackingDemandPolicy)
        if cameBack { wake() }
    }

    /// How many screens hold the engine now.
    public private(set) var holders = 0
    private var foreground = true

    /// The feed poll's interval now; nil = don't poll until woken.
    /// Swap-in point for FeedCadencePolicy (MVTRAX-18 step 3).
    func pollInterval() -> Duration? {
        FeedCadencePolicy.interval(holds: holders, foreground: foreground)
    }

    private var nap: Task<Void, Never>?
    private var wakeRequested = false
    private var lastOutgoingRefresh: Date?
    private var lastPlacesRefresh: Date?
    static let outgoingEvery: TimeInterval = 20
    static let placesEvery: TimeInterval = 120

    /// The sleep before the next tick: none if a wake is pending, else the
    /// current interval (cut short by `wake()`).
    private func nextNap() -> Task<Void, Never> {
        if wakeRequested { return Task {} }
        let interval = pollInterval() ?? .seconds(3600)
        let t = Task { _ = try? await Task.sleep(for: interval) }
        nap = t
        return t
    }

    /// Poll now: cut the current nap short, or run once more right after the
    /// tick in progress.
    private func wake() {
        guard pollTask != nil else { return }
        wakeRequested = true
        nap?.cancel()
    }

    /// Stop polling and posting. Work already in flight finishes without
    /// writing anything (the sync layer drops results from before the stop).
    public func stop() {
        sync.invalidate()
        nap?.cancel(); nap = nil
        pollTask?.cancel(); fixTask?.cancel(); transitionTask?.cancel(); expiryTask?.cancel()
        pollTask = nil; fixTask = nil; transitionTask = nil; expiryTask = nil
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
        wakeRequested = false
        await sync.loadContacts()
        await sync.loadPlaces()
        await sync.refresh()
        await sync.refreshOutgoing()
        lastOutgoingRefresh = Date(); lastPlacesRefresh = Date()
        pushRegions()
        pushDemand()
        observeSharing()
    }

    /// One poll: the feed every tick; my outgoing shares and places on their
    /// own slower clocks, so a fast held cadence doesn't multiply them.
    private func pollTick() async {
        wakeRequested = false
        sync.flushPendingTrack()   // a fix whose post failed goes out even if no new fix arrives
        await sync.refresh()
        let now = Date()
        if lastOutgoingRefresh.map({ now.timeIntervalSince($0) >= Self.outgoingEvery }) ?? true {
            await sync.refreshOutgoing()
            lastOutgoingRefresh = now
        }
        if lastPlacesRefresh.map({ now.timeIntervalSince($0) >= Self.placesEvery }) ?? true {
            await sync.loadPlaces(); pushRegions()
            lastPlacesRefresh = now
        }
        pushDemand()
    }

    /// Fetch my places (and the ones shared with me) now, rather than on the
    /// poll's slower places clock: for a screen that lists them, on open. A
    /// running engine also re-hands the geofence its regions; a stopped one
    /// leaves the host's geofence alone.
    public func reloadPlaces() async {
        await sync.loadPlaces()
        guard pollTask != nil else { return }
        lastPlacesRefresh = Date()
        pushRegions()
    }

    /// Re-hand the kit's place-regions to the host's geofence (its rolling-20 merges
    /// them). Call after a place edit for an immediate update; the poll also refreshes.
    public func pushRegions() {
        host.setMonitoredRegions(store.allPlaces().map {
            TraxRegion(placeID: $0.id, lat: $0.lat, lng: $0.lng, radiusMeters: Double($0.radiusM))
        })
    }

    private func pushDemand() {
        host.setDesiredTracking(TrackingDemandPolicy.demand(
            precisions: sync.livePrecisions, auth: host.authorization, foreground: foreground))
    }

    /// React to share start/stop immediately → update the host's tracking demand.
    /// Re-push demand whenever the producer's "am I sharing" answer can change:
    /// the outgoing list, a track ack, or a share reaching its expiry. Reading
    /// `isSharing` tracks both stored inputs; expiry is time, so it gets a
    /// one-shot at the earliest future expiresAt.
    ///
    /// Background truth (MVTRAX-18 step 9): with no feed poll in the background,
    /// the producer relies on local expiry plus each post's ack. A share stopped
    /// elsewhere ends at the next ack. A share started elsewhere while demand
    /// is .off waits for the foreground refresh, since an app with no location
    /// demand gets no background time to refresh in.
    private func observeSharing() {
        withObservationTracking { _ = sync.isSharing } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.pollTask != nil else { return }
                self.pushDemand()
                self.observeSharing()
            }
        }
        scheduleExpiryCheck()
    }

    private func scheduleExpiryCheck() {
        expiryTask?.cancel()
        let now = Date()
        guard let next = sync.outgoing.compactMap(\.expiresAt)
            .map({ Date(timeIntervalSince1970: TimeInterval($0) / 1000) })
            .filter({ $0 > now }).min() else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now) + 0.5))
            guard !Task.isCancelled, let self, self.pollTask != nil else { return }
            self.pushDemand()
            self.scheduleExpiryCheck()
        }
    }
}
