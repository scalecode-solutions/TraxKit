import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// The whole TraxKit surface: a full-screen map with a draggable glass bottom
/// sheet (Life360 / Tangle model). One screen, three pills — People / Weather /
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

    @Query(sort: \ShareEntity.updatedAt, order: .reverse) private var incoming: [ShareEntity]
    @Query(sort: \ContactEntity.name) private var contacts: [ContactEntity]
    @Query private var places: [PlaceEntity]

    @State private var pill: HubPill = .people
    @State private var detent: HubDetent = .mid
    @State private var dragOffset: CGFloat = 0
    @State private var mapStyle: TraxMapStyle = .standard
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var detailID: String?           // nil = hub; else a person id
    @State private var weatherPage: TraxWeatherPage = .mine
    @State private var followSpan = MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
    @State private var showShareSheet = false
    @State private var editing: PlaceEdit?
    @State private var historyTarget: HistoryTarget?
    @State private var weatherTarget: WeatherTarget?

    // MARK: derived people

    private var contactsByID: [UUID: ContactEntity] {
        Dictionary(contacts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private func name(for id: UUID) -> String {
        let n = contactsByID[id]?.name
        if let n, !n.isEmpty { return n }
        return "Member \(id.uuidString.prefix(8))"
    }
    private func avatar(for id: UUID) -> String? { contactsByID[id]?.avatar }

    private func placeMatch(_ coord: CLLocationCoordinate2D) -> PlaceEntity? {
        places.first { p in
            CLLocation(latitude: p.lat, longitude: p.lng)
                .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude)) <= Double(p.radiusM)
        }
    }

    private var selfPerson: TraxPerson? {
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

    private var peers: [TraxPerson] {
        incoming.compactMap { s in
            guard let lat = s.lat, let lng = s.lng else { return nil }
            let st = s.status()
            return TraxPerson(id: s.id.uuidString, ownerId: s.ownerId, name: name(for: s.ownerId),
                              avatar: avatar(for: s.ownerId),
                              coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                              isSelf: false, precision: s.precision, status: st, battery: st.battery,
                              placeName: s.placeName, placeEmoji: s.placeEmoji,
                              atPlace: s.atPlace, fuzzRadiusM: s.fuzzRadiusM)
        }
    }

    private var people: [TraxPerson] { (selfPerson.map { [$0] } ?? []) + peers }
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
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { TraxSettingsView(sync: sync, onSignOut: onSignOut) } label: {
                        Image(systemName: "gearshape").font(.system(size: 17, weight: .medium))
                    }
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
            .onChange(of: followKey) { _, _ in followSubject() }
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
                    .foregroundStyle(Color.accentColor.opacity(0.15))
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
            }
            ForEach(people) { p in
                Annotation(p.displayName, coordinate: p.coordinate) {
                    AvatarPin(id: p.ownerId, name: p.name, avatar: p.avatar, selected: detailID == p.id, live: p.isLive)
                        .onTapGesture { enterDetail(p) }
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
            .background(.ultraThinMaterial, in: .capsule)
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .disabled(true)
    }

    private var layersMenu: some View {
        Menu {
            Picker("Map style", selection: $mapStyle) {
                ForEach(TraxMapStyle.allCases) { Text($0.label).tag($0) }
            }
        } label: { controlIcon("square.3.layers.3d") }
    }

    private var recenterButton: some View {
        Button { recenter() } label: { controlIcon("location.fill") }.buttonStyle(.plain)
    }

    private func controlIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 16, weight: .medium))
            .frame(width: 40, height: 40).background(.ultraThinMaterial, in: .circle)
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    // MARK: panel

    private func panel(available: CGFloat) -> some View {
        let h = panelHeight(available: available)
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule().fill(.secondary.opacity(0.35)).frame(width: 38, height: 5)
                    .padding(.top, 8).padding(.bottom, 6)
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
            .scrollDisabled(detent != .full)
        }
        .frame(height: h, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: .rect(topLeadingRadius: 22, topTrailingRadius: 22))
        .shadow(color: .black.opacity(0.12), radius: 10, y: -4)
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
                        .foregroundStyle(pill == p ? .white : Color.accentColor)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(pill == p ? Color.accentColor : Color.accentColor.opacity(0.12), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            Button { exitDetail() } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32).background(.ultraThinMaterial, in: .circle)
            }
            .buttonStyle(.plain)
            Text(detailSubject?.displayName ?? "Details").font(.system(size: 20, weight: .bold)).lineLimit(1)
            Spacer()
        }
    }

    // MARK: camera + detail transitions

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

enum HubPill: String, CaseIterable, Identifiable {
    case people, weather, places
    var id: Self { self }
    var symbol: String {
        switch self { case .people: "person.2.fill"; case .weather: "cloud.sun.fill"; case .places: "building.2.fill" }
    }
}

enum HubDetent: CaseIterable {
    case peek, mid, full
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
