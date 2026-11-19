import SwiftUI
import MapKit
import CoreLocation

/// The whole TraxKit surface: a full-screen map with a draggable glass bottom
/// sheet (Life360 model). One screen, three pills — People / Weather /
/// Places — and the map content swaps to match. "You" is the first row in People,
/// and tapping any person (self or sharer) swaps the panel into a detail stack.
/// Replaces the old TabView; `TraxRootView` hosts it and owns the poll loop.
public struct TraxHub: View {
    let engine: TraxEngine
    let embedded: Bool
    let onSignOut: (() -> Void)?

    private var sync: TraxSync { engine.sync }
    private var weather: TraxWeatherStore { engine.weather }
    private var geocoder: TraxGeocoder { engine.geocoder }
    /// Self coordinate from the host's latest fix (replaces TraxSelfState).
    private var selfCoordinate: CLLocationCoordinate2D? {
        engine.currentFix.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
    }

    public init(engine: TraxEngine, embedded: Bool = false, onSignOut: (() -> Void)? = nil) {
        self.engine = engine; self.embedded = embedded; self.onSignOut = onSignOut
    }

    // Published values from the engine (no SwiftData reads in a body).
    private var incoming: [IncomingShareSnapshot] { sync.incomingList }
    private var contacts: [TraxContact] { sync.contacts }
    private var places: [PlaceSnapshot] { sync.placeSnapshots }

    @State private var pill: HubPill = .people
    @State private var detent: HubDetent = .mid
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @State private var dragOffset: CGFloat = 0
    @State private var mapStyle: TraxMapStyle = .standard
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var framedEveryone = false
    @State private var detailID: String?           // nil = hub; else a person id
    @State private var weatherPage: TraxWeatherPage = .mine
    @State private var followSpan = MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
    @State private var showShareSheet = false
    @State private var editing: PlaceEdit?
    @State private var historyTarget: HistoryTarget?
    @State private var weatherTarget: WeatherTarget?

    // MARK: derived people

    private var contactsByID: [UUID: TraxContact] { sync.contactsByID }
    private func name(for id: UUID) -> String {
        let n = contactsByID[id]?.name
        if let n, !n.isEmpty { return n }
        return "Member \(id.uuidString.prefix(8))"
    }
    private func avatar(for id: UUID) -> String? { contactsByID[id]?.avatar }

    private func placeMatch(_ coord: CLLocationCoordinate2D) -> PlaceSnapshot? {
        places.first { p in
            CLLocation(latitude: p.lat, longitude: p.lng)
                .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude)) <= Double(p.radiusM)
        }
    }

    /// The derived people, rebuilt only when what they're made of changes. The
    /// hub re-renders on every frame of a sheet drag, and each person (status,
    /// place match, battery) used to be rebuilt several times per render.
    @State private var peopleMemo = HubPeopleMemo()

    private var derived: HubPeopleMemo.Value {
        let fix = engine.currentFix
        let key = HubPeopleMemo.Key(
            incoming: incoming, contacts: contacts, places: places,
            fixLat: fix?.lat, fixLng: fix?.lng, battery: fix?.batteryLevel, charging: fix?.batteryCharging,
            // Statuses age with the clock ("Just now" → "3 min ago"): rebuild at least every 30 s.
            clock: Int(Date().timeIntervalSince1970 / 30))
        return peopleMemo.value(for: key) { (buildSelfPerson(), buildPeers()) }
    }
    private var selfPerson: TraxPerson? { derived.selfPerson }
    private var peers: [TraxPerson] { derived.peers }

    private func buildSelfPerson() -> TraxPerson? {
        guard let c = selfCoordinate else { return nil }
        let me = contactsByID[sync.currentUserID]
        let match = placeMatch(c)
        let nm = me?.name.isEmpty == false ? me!.name : "You"
        return TraxPerson(id: "self", ownerId: sync.currentUserID, name: nm, avatar: me?.avatar,
                          coordinate: c, isSelf: true, precision: "exact", status: nil,
                          battery: TraxBatteryStatus(level: engine.currentFix?.batteryLevel,
                                                     charging: engine.currentFix?.batteryCharging ?? false),
                          placeName: match?.name, placeEmoji: match?.emoji,
                          atPlace: match != nil, fuzzRadiusM: nil)
    }

    private func buildPeers() -> [TraxPerson] {
        incoming.compactMap { s in
            guard let lat = s.lat, let lng = s.lng else { return nil }
            let st = s.status()
            return TraxPerson(id: s.shareID.uuidString, ownerId: s.ownerID, name: name(for: s.ownerID),
                              avatar: avatar(for: s.ownerID),
                              coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                              isSelf: false, precision: s.precision, status: st, battery: st.battery,
                              placeName: s.placeName, placeEmoji: s.placeEmoji,
                              atPlace: s.atPlace, fuzzRadiusM: s.fuzzRadiusM)
        }
    }

    private var people: [TraxPerson] { (selfPerson.map { [$0] } ?? []) + peers }
    /// What VoiceOver says for a person's pin: who, and where if known.
    private func pinLabel(_ p: TraxPerson) -> String {
        var parts = [p.displayName]
        if let place = p.placeName, p.atPlace { parts.append("at \(place)") }
        if let s = p.status, !p.isSelf { parts.append(s.lastUpdated) }
        return parts.joined(separator: ", ")
    }

    private var detailSubject: TraxPerson? { detailID.flatMap { id in people.first { $0.id == id } } }

    // MARK: body

    public var body: some View {
        if embedded { hubBody } else { NavigationStack { hubBody } }
    }

    @ViewBuilder private var hubBody: some View {
            GeometryReader { geo in
                let h = panelHeight(available: geo.size.height)
                ZStack(alignment: .bottom) {
                    map
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: max(0, h - HubMetrics.handle))
                        }
                    floatingControls
                        .padding(.bottom, h + 12)
                        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: detent)
                    panel(available: geo.size.height)
                }
            }
            .overlay(alignment: .top) { errorBanner }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)   // title + gear float over the map
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .topBarLeading) {
                        Text("Trax").font(.system(size: 26, weight: .bold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showShareSheet = true } label: {
                        Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 17, weight: .medium))
                    }
                    .accessibilityLabel("Share my location")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        TraxSettingsView(engine: engine) {
                            if let onSignOut {
                                Section { Button("Sign Out", role: .destructive) { onSignOut() } }
                            }
                        }
                    } label: {
                        Image(systemName: "gearshape").font(.system(size: 17, weight: .medium))
                    }
                    .accessibilityLabel("Location settings")
                }
            }
            .sheet(isPresented: $showShareSheet) {
                TraxShareSheet(engine: engine).presentationDetents([.medium, .large])
            }
            .sheet(item: $editing) { mode in PlaceEditor(engine: engine, mode: mode) }
            .navigationDestination(item: $historyTarget) { t in
                TraxTimelineView(sync: sync, owner: t.ownerId, title: t.name)
            }
            .navigationDestination(item: $weatherTarget) { t in
                TraxWeatherDetailView(store: weather, latitude: t.lat, longitude: t.lng, title: "\(t.name)'s Weather")
            }
            .onChange(of: pill) { _, _ in detailID = nil }
            // The person being viewed stopped sharing (or their share expired):
            // back to the hub rather than an empty detail panel.
            .onChange(of: detailID != nil && detailSubject == nil) { _, gone in
                if gone { detailID = nil }
            }
            .onChange(of: followKey) { _, _ in followSubject() }
            // On open, frame everyone sharing with me as well as me, once: the
            // first time their locations are in. After that the camera is the
            // user's (or follows a selected person).
            .onChange(of: peers.map(\.id), initial: true) { _, ids in
                guard !framedEveryone, detailID == nil, !ids.isEmpty else { return }
                framedEveryone = true
                if let region = Self.fitting(people.map(\.coordinate)) {
                    withAnimation(.easeInOut) { camera = .region(region) }
                }
            }
    }

    @ViewBuilder private var errorBanner: some View {
        if let err = sync.lastError {
            Text(err).font(.caption).padding(8)
                .background(.red.opacity(0.85), in: .capsule).foregroundStyle(.white).padding(.top, 8)
        }
    }

    // MARK: map

    /// Effective map mode — detail always shows people pins so the subject is visible.
    private var mapMode: HubPill { detailID != nil ? .people : pill }

    private var map: some View {
        Map(position: $camera) { mapContent }
            .mapStyle(mapStyle.style)
            .onMapCameraChange(frequency: .onEnd) { ctx in
                if detailID != nil { followSpan = ctx.region.span }
            }
            .ignoresSafeArea()
    }

    @MapContentBuilder private var mapContent: some MapContent {
        switch mapMode {
        case .people:
            ForEach(peers.filter { $0.precision == "approx" && $0.fuzzRadiusM != nil }) { p in
                MapCircle(center: p.coordinate, radius: p.fuzzRadiusM ?? 900)
                    .foregroundStyle(.tint.opacity(0.15))
                    .stroke(.tint.opacity(0.5), lineWidth: 1)
            }
            ForEach(people) { p in
                Annotation(p.displayName, coordinate: p.coordinate) {
                    AvatarPin(id: p.ownerId, name: p.name, avatar: p.avatar, selected: detailID == p.id, live: p.isLive)
                        .onTapGesture { enterDetail(p) }
                        .accessibilityElement()
                        .accessibilityLabel(pinLabel(p))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { enterDetail(p) }
                }
            }
        case .places:
            ForEach(places) { p in
                Marker(p.name, monogram: Text(p.emoji ?? "📍"),
                       coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng))
                    .tint(.secondary)
            }
        case .weather:
            ForEach(people) { p in
                Annotation(p.displayName, coordinate: p.coordinate) {
                    TraxWeatherPin(store: weather, latitude: p.coordinate.latitude, longitude: p.coordinate.longitude)
                        .onTapGesture { weatherTarget = WeatherTarget(ownerId: p.ownerId, name: p.name,
                                                                      lat: p.coordinate.latitude, lng: p.coordinate.longitude) }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Weather for \(p.displayName)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { weatherTarget = WeatherTarget(ownerId: p.ownerId, name: p.name,
                                                                            lat: p.coordinate.latitude, lng: p.coordinate.longitude) }
                }
            }
        }
    }

    // MARK: floating controls

    private var floatingControls: some View {
        HStack(spacing: 10) {
            checkInButton
            Spacer()
            layersMenu
            recenterButton
        }
        .padding(.horizontal, 16)
    }

    // Stubbed visible until check-in is reworked properly (see discussion).
    private var checkInButton: some View {
        Button {} label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 14, weight: .medium))
                Text("Check in").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .traxGlass(in: .capsule)
        }
        .disabled(true)
    }

    private var layersMenu: some View {
        Menu {
            Picker("Map style", selection: $mapStyle) {
                ForEach(TraxMapStyle.allCases) { Text($0.label).tag($0) }
            }
        } label: { controlIcon("square.3.layers.3d") }
        .accessibilityLabel("Map style")
    }

    private var recenterButton: some View {
        Button { recenter() } label: { controlIcon("location.fill") }.buttonStyle(.plain)
            .accessibilityLabel("Center on me")
    }

    private func controlIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 16, weight: .medium))
            .frame(width: 40, height: 40)
            .traxGlass(in: .circle, interactive: true)
    }

    // MARK: panel

    private func panel(available: CGFloat) -> some View {
        let h = panelHeight(available: available)
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule().fill(.secondary.opacity(0.35)).frame(width: 38, height: 5)
                    .padding(.top, 8).padding(.bottom, 6)
                    // VoiceOver and Switch Control can't drag: the handle is an
                    // adjustable control (swipe up/down to resize the panel).
                    .frame(maxWidth: .infinity)
                    .accessibilityElement()
                    .accessibilityLabel("Panel")
                    .accessibilityValue(detent.accessibilityValue)
                    .accessibilityAdjustableAction { direction in
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            detent = direction == .increment ? detent.larger : detent.smaller
                        }
                    }
                if detailID == nil {
                    pillRow.padding(.horizontal, 16).padding(.vertical, 8)
                } else {
                    detailHeader.padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(available: available))

            ScrollView {
                VStack(spacing: 0) { panelContent }
            }
            // Dragging scrolls the panel itself until it's full; with VoiceOver
            // there's no drag, so the rows must always scroll into reach.
            .scrollDisabled(detent != .full && !voiceOverOn)
        }
        .frame(height: h, alignment: .top)
        .frame(maxWidth: .infinity)
        .background {
            // Liquid Glass over the map, as the sibling kits' sheets. Rounded top,
            // but it runs into the bottom safe area so it fills behind a host
            // tab bar and the home indicator. Reads the inset implicitly — works
            // for the bare home indicator (TraxLab standalone) and a host's tab
            // bar alike.
            Color.clear
                .traxGlass(in: UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 0,
                                                      bottomTrailingRadius: 0, topTrailingRadius: 22))
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: detent)
    }

    @ViewBuilder private var panelContent: some View {
        if let subject = detailSubject {
            if subject.isSelf {
                TraxMeView(
                    person: subject, sync: sync, weather: weather, geocoder: geocoder,
                    onShare: { showShareSheet = true },
                    onWeather: { weatherTarget = WeatherTarget(ownerId: subject.ownerId, name: subject.name,
                                                               lat: subject.coordinate.latitude, lng: subject.coordinate.longitude) },
                    onHistory: { historyTarget = HistoryTarget(ownerId: subject.ownerId, name: subject.name) })
            } else {
                TraxHubDetailContent(
                    person: subject, sync: sync, weather: weather, geocoder: geocoder,
                    selfCoordinate: selfCoordinate, myPlaces: places,
                    onShare: { showShareSheet = true },
                    onWeather: { weatherTarget = WeatherTarget(ownerId: subject.ownerId, name: subject.name,
                                                               lat: subject.coordinate.latitude, lng: subject.coordinate.longitude) },
                    onHistory: { historyTarget = HistoryTarget(ownerId: subject.ownerId, name: subject.name) })
            }
        } else {
            switch pill {
            case .people:
                TraxHubPeopleContent(people: people, geocoder: geocoder, onTap: enterDetail)
            case .weather:
                TraxHubWeatherContent(selfPerson: selfPerson, peers: peers, weather: weather, page: $weatherPage,
                    onForecast: { p in weatherTarget = WeatherTarget(ownerId: p.ownerId, name: p.name,
                                                                     lat: p.coordinate.latitude, lng: p.coordinate.longitude) },
                    onFocus: { focus(on: $0) })
            case .places:
                TraxHubPlacesContent(places: places, currentUserID: sync.currentUserID, nameFor: { name(for: $0) },
                                     onAdd: { editing = .new }, onEdit: { editing = .existing($0) })
            }
        }
    }

    private var pillRow: some View {
        HStack(spacing: 10) {
            ForEach(HubPill.allCases) { p in
                Button { withAnimation(.easeInOut) { pill = p } } label: {
                    Image(systemName: p.symbol).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(pill == p ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(pill == p ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.12)), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.title)
                .accessibilityAddTraits(pill == p ? .isSelected : [])
            }
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            Button { exitDetail() } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32).background(.ultraThinMaterial, in: .circle)
                    .frame(width: 44, height: 44).contentShape(.rect)   // 44 pt target around the 32 pt disc
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            Text(detailSubject?.displayName ?? "Details").font(.system(size: 20, weight: .bold)).lineLimit(1)
            Spacer()
        }
    }

    // MARK: camera + detail transitions

    /// A region that shows every coordinate with some margin (nil for none).
    static func fitting(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.latitude), lngs = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                            longitude: (lngs.min()! + lngs.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.02, (lats.max()! - lats.min()!) * 1.6),
                                    longitudeDelta: max(0.02, (lngs.max()! - lngs.min()!) * 1.6))
        return MKCoordinateRegion(center: center, span: span)
    }

    private var followKey: String {
        guard detailID != nil, let c = detailSubject?.coordinate else { return "" }
        return "\(c.latitude),\(c.longitude)"
    }
    private func followSubject() {
        guard detailID != nil, let c = detailSubject?.coordinate else { return }
        withAnimation(.easeInOut(duration: 0.5)) {
            camera = .region(MKCoordinateRegion(center: c, span: followSpan))
        }
    }
    private func enterDetail(_ p: TraxPerson) {
        followSpan = MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            detailID = p.id
            detent = .full
            camera = .region(MKCoordinateRegion(center: p.coordinate, span: followSpan))
        }
    }
    private func exitDetail() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { detailID = nil; detent = .mid }
    }
    private func focus(on p: TraxPerson) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            camera = .region(MKCoordinateRegion(center: p.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)))
        }
    }
    private func recenter() {
        if let c = selfCoordinate {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                camera = .region(MKCoordinateRegion(center: c,
                    span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)))
            }
        } else {
            withAnimation { camera = .userLocation(fallback: .automatic) }
        }
    }

    // MARK: detent math

    private var rowCount: Int {
        if detailID != nil { return 99 }
        switch pill {
        case .people:  return max(people.count, 1)
        case .weather: return 99
        case .places:  return places.count + 1
        }
    }
    private func panelHeight(available: CGFloat) -> CGFloat {
        let base = detent.height(available: available, rowCount: rowCount)
        return max(HubDetent.peek.height(available: available, rowCount: rowCount),
                   min(HubDetent.full.height(available: available, rowCount: rowCount), base - dragOffset))
    }
    private func dragGesture(available: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { dragOffset = $0.translation.height }
            .onEnded { value in
                let base = detent.height(available: available, rowCount: rowCount)
                let predicted = base - value.predictedEndTranslation.height
                let closest = HubDetent.allCases
                    .map { ($0, $0.height(available: available, rowCount: rowCount)) }
                    .min { abs($0.1 - predicted) < abs($1.1 - predicted) }!
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    detent = closest.0; dragOffset = 0
                }
            }
    }
}

// MARK: - Hub types

/// Holds the hub's derived people between renders (a reference, so reading it
/// in a body doesn't count as a state change).
@MainActor
final class HubPeopleMemo {
    struct Key: Equatable {
        let incoming: [IncomingShareSnapshot]
        let contacts: [TraxContact]
        let places: [PlaceSnapshot]
        let fixLat: Double?, fixLng: Double?
        let battery: Int?, charging: Bool?
        let clock: Int
    }
    typealias Value = (selfPerson: TraxPerson?, peers: [TraxPerson])
    private var key: Key?
    private var cached: Value = (nil, [])
    private(set) var builds = 0

    func value(for key: Key, build: () -> Value) -> Value {
        if key != self.key {
            cached = build()
            self.key = key
            builds += 1
        }
        return cached
    }
}

enum HubPill: String, CaseIterable, Identifiable {
    case people, weather, places
    var id: Self { self }
    var symbol: String {
        switch self { case .people: "person.2.fill"; case .weather: "cloud.sun.fill"; case .places: "building.2.fill" }
    }
    var title: String {
        switch self { case .people: "People"; case .weather: "Weather"; case .places: "Places" }
    }
}

enum HubDetent: CaseIterable {
    case peek, mid, full
    var larger: HubDetent { self == .peek ? .mid : .full }
    var smaller: HubDetent { self == .full ? .mid : .peek }
    var accessibilityValue: String {
        switch self { case .peek: "Collapsed"; case .mid: "Half"; case .full: "Expanded" }
    }
    func height(available: CGFloat, rowCount: Int) -> CGFloat {
        switch self {
        case .peek: HubMetrics.header + 8
        case .mid:  HubMetrics.header + 2 * HubMetrics.row
        case .full: min(HubMetrics.header + CGFloat(rowCount) * HubMetrics.row, available)
        }
    }
}

enum HubMetrics {
    static let handle: CGFloat = 19
    static let pillRow: CGFloat = 52
    static let row: CGFloat = 77
    static var header: CGFloat { handle + pillRow }
}

/// Map style choices (the layers menu).
enum TraxMapStyle: String, CaseIterable, Identifiable {
    case standard, hybrid, satellite
    var id: Self { self }
    var label: String {
        switch self { case .standard: "Standard"; case .hybrid: "Hybrid"; case .satellite: "Satellite" }
    }
    var style: MapStyle {
        switch self {
        case .standard:  .standard(elevation: .realistic)
        case .hybrid:    .hybrid(elevation: .realistic)
        case .satellite: .imagery(elevation: .realistic)
        }
    }
}

/// Push target for a friend's full timeline.
struct HistoryTarget: Identifiable, Hashable {
    let ownerId: UUID
    let name: String
    var id: UUID { ownerId }
}

/// Push target for a person's full forecast (coords carried so the screen is self-contained).
struct WeatherTarget: Identifiable, Hashable {
    let ownerId: UUID
    let name: String
    let lat: Double
    let lng: Double
    var id: UUID { ownerId }
}
