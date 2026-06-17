import SwiftUI
import SwiftData
import MapKit

/// Live-share length when starting a share (mirrors Tangle's options; default
/// 15 min, with "Until I stop" = indefinite). See mvTrax/docs/DESIGN.md.
public enum ShareDuration: CaseIterable, Identifiable, Sendable {
    case fifteenMinutes, oneHour, eightHours, indefinite
    public var id: Self { self }
    public var label: String {
        switch self {
        case .fifteenMinutes: "15 min"
        case .oneHour:        "1 hour"
        case .eightHours:     "8 hours"
        case .indefinite:     "Until I stop"
        }
    }
    public var expiresInSeconds: Int? {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .oneHour:        60 * 60
        case .eightHours:     8 * 60 * 60
        case .indefinite:     nil
        }
    }
}

/// The map of who's sharing their location with you (the primary surface), plus
/// the share controls. A composable piece — `TraxRootView` hosts it in a tab and
/// owns the producer + poll loop; a host could also embed it directly. Pull-feed
/// driven (HTTP poll) — no socket.
public struct TraxMapView: View {
    let sync: TraxSync
    let weather: TraxWeatherStore
    public init(sync: TraxSync, weather: TraxWeatherStore) { self.sync = sync; self.weather = weather }
    public var body: some View { TraxMapScreen(sync: sync, weather: weather) }
}

struct TraxMapScreen: View {
    let sync: TraxSync
    let weather: TraxWeatherStore

    @Query(sort: \ShareEntity.updatedAt, order: .reverse) private var incoming: [ShareEntity]
    @Query(sort: \ContactEntity.name) private var contacts: [ContactEntity]
    @Query private var places: [PlaceEntity]

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selected: UUID?
    @State private var showShareSheet = false
    @State private var detail: MemberCard?
    @State private var historyTarget: HistoryTarget?   // pushes the full timeline for a friend
    @State private var weatherTarget: WeatherTarget?   // pushes the full forecast for a friend
    @State private var showWeatherPins = false         // temp badges on every sharer pin
    @State private var style: TraxMapStyle = .standard
    /// While a member card is open (and no journey trail is up), follow this
    /// owner: re-center on their new fixes, map panning behind them. Cleared when
    /// the card closes or a journey takes over the camera.
    @State private var following: UUID?
    @State private var lastSpan: MKCoordinateSpan?

    private var contactsByID: [UUID: ContactEntity] {
        Dictionary(contacts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private var plottable: [ShareEntity] { incoming.filter(\.hasLocation) }

    func name(for id: UUID) -> String {
        let c = contactsByID[id]
        if let n = c?.name, !n.isEmpty { return n }
        return "Member \(id.uuidString.prefix(8))"
    }
    private func avatar(for id: UUID) -> String? { contactsByID[id]?.avatar }

    /// Build the detail card snapshot for a share (status evaluated now).
    private func card(for s: ShareEntity) -> MemberCard? {
        guard let lat = s.lat, let lng = s.lng else { return nil }
        return MemberCard(id: s.id, ownerId: s.ownerId, name: name(for: s.ownerId),
                          avatar: avatar(for: s.ownerId), status: s.status(),
                          coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng))
    }

    private func coordinate(of id: UUID) -> CLLocationCoordinate2D? {
        guard let s = plottable.first(where: { $0.id == id }), let lat = s.lat, let lng = s.lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// On selection change: open the glance card + follow the member's live fixes.
    private func onSelect(_ id: UUID?) {
        focus(on: id)
        if let id, let sh = plottable.first(where: { $0.id == id }) {
            detail = card(for: sh)
            following = sh.ownerId   // follow their live position
        } else {
            detail = nil
            following = nil
        }
    }

    /// Re-key the weather sweep when the toggle flips or sharer positions move
    /// across regions (keeps badges warm without refetching block-to-block).
    private var weatherPinsKey: String {
        guard showWeatherPins else { return "off" }
        return plottable.map { "\(Int((($0.lat ?? 0)) * 10)),\(Int((($0.lng ?? 0)) * 10))" }
            .sorted().joined(separator: "|")
    }

    /// Coordinate key of the followed owner — changes when their fix updates.
    private var followKey: String {
        guard let f = following, let s = plottable.first(where: { $0.ownerId == f }) else { return "" }
        return "\(s.lat ?? 0),\(s.lng ?? 0)"
    }

    /// Re-center on the followed owner, preserving the user's current zoom.
    private func followRecenter() {
        guard let f = following, let s = plottable.first(where: { $0.ownerId == f }),
              let lat = s.lat, let lng = s.lng else { return }
        let span = lastSpan ?? MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lng), span: span))
        }
    }

    private func focusCoord(_ coord: CLLocationCoordinate2D, span: Double) {
        withAnimation(.easeInOut) {
            camera = .region(MKCoordinateRegion(center: coord,
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
        }
    }

    /// Animate the camera onto a sharer when their marker is tapped/selected.
    private func focus(on id: UUID?) {
        guard let id, let coord = coordinate(of: id) else { return }
        focusCoord(coord, span: 0.01)
    }

    @MapContentBuilder private var mapContent: some MapContent {
        UserAnnotation()   // the signed-in user's own blue dot
        // Own saved places — muted context pins.
        ForEach(places) { p in
            Marker(p.name, monogram: Text(p.emoji ?? "📍"),
                   coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng))
                .tint(.secondary)
        }
        // Approx-precision sharers: a fuzz circle around the coarse location.
        ForEach(plottable.filter { $0.precision == "approx" && $0.fuzzRadiusM != nil }) { s in
            MapCircle(center: CLLocationCoordinate2D(latitude: s.lat ?? 0, longitude: s.lng ?? 0),
                      radius: s.fuzzRadiusM ?? 900)
                .foregroundStyle(Color.accentColor.opacity(0.15))
                .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
        }
        // Sharers — avatar pins (Life360 feel). For place tier the pin sits at the
        // place center; for approx, at the fuzzed center inside its circle.
        ForEach(plottable) { s in
            Annotation(name(for: s.ownerId),
                       coordinate: CLLocationCoordinate2D(latitude: s.lat ?? 0, longitude: s.lng ?? 0)) {
                AvatarPin(id: s.ownerId, name: name(for: s.ownerId),
                          avatar: avatar(for: s.ownerId), selected: selected == s.id,
                          tempText: showWeatherPins
                            ? weather.cached(latitude: s.lat ?? 0, longitude: s.lng ?? 0)?.tempText : nil)
            }
            .tag(s.id)
        }
    }

    var body: some View {
        Map(position: $camera, selection: $selected) { mapContent }
        .mapStyle(style.style)
        .onMapCameraChange(frequency: .onEnd) { ctx in lastSpan = ctx.region.span }
        .onChange(of: selected) { _, new in onSelect(new) }
        .onChange(of: followKey) { _, _ in followRecenter() }
        .task(id: weatherPinsKey) {
            guard showWeatherPins else { return }
            for s in plottable {
                await weather.refresh(latitude: s.lat ?? 0, longitude: s.lng ?? 0)
            }
        }
        .overlay(alignment: .top) {
            if let err = sync.lastError {
                Text(err).font(.caption).padding(8)
                    .background(.red.opacity(0.85), in: .capsule)
                    .foregroundStyle(.white).padding(.top, 8)
            }
        }
        .overlay(alignment: .topLeading) { mapControls }
        .overlay(alignment: .bottom) { peopleBar }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showShareSheet = true } label: { Image(systemName: "person.crop.circle.badge.plus") }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            TraxShareSheet(sync: sync).presentationDetents([.medium, .large])
        }
        .sheet(item: $detail) { c in
            TraxMemberDetail(card: c, sync: sync, weather: weather, onWeather: {
                detail = nil                 // dismiss the glance…
                weatherTarget = WeatherTarget(ownerId: c.ownerId, name: c.name,
                                              lat: c.coordinate.latitude, lng: c.coordinate.longitude)
            }, onHistory: {
                detail = nil                 // dismiss the glance…
                historyTarget = HistoryTarget(ownerId: c.ownerId, name: c.name)  // …push their timeline
            })
            .presentationDetents([.height(220), .medium])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
        }
        .onChange(of: detail?.id) { _, id in
            if id == nil { selected = nil }  // card dismissed → stop follow next tick
        }
        .navigationDestination(item: $historyTarget) { t in
            TraxTimelineView(sync: sync, owner: t.ownerId, title: t.name)
        }
        .navigationDestination(item: $weatherTarget) { t in
            TraxWeatherDetailView(store: weather, latitude: t.lat, longitude: t.lng,
                                  title: "\(t.name)'s Weather")
        }
    }

    /// Floating map controls: style toggle + recenter-on-me.
    private var mapControls: some View {
        VStack(spacing: 10) {
            Menu {
                Picker("Map style", selection: $style) {
                    ForEach(TraxMapStyle.allCases) { Text($0.label).tag($0) }
                }
            } label: { controlIcon("map") }
            Button { withAnimation { camera = .userLocation(fallback: .automatic) } } label: {
                controlIcon("location.fill")
            }
            Button { withAnimation { showWeatherPins.toggle() } } label: {
                controlIcon(showWeatherPins ? "thermometer.medium" : "thermometer.low")
                    .foregroundStyle(showWeatherPins ? Color.accentColor : .primary)
            }
        }
        .padding(.leading, 12).padding(.top, 8)
    }

    private func controlIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .medium))
            .frame(width: 40, height: 40)
            .background(.thinMaterial, in: .circle)
    }

    @ViewBuilder private var peopleBar: some View {
        if plottable.isEmpty {
            Text(incoming.isEmpty ? "No one is sharing with you yet" : "Sharers located soon…")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(10).background(.thinMaterial, in: .capsule).padding(.bottom, 12)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(plottable) { s in
                        let st = s.status()
                        Button { selected = s.id } label: {   // onSelect opens the card
                            HStack(spacing: 8) {
                                TraxAvatar(id: s.ownerId, name: name(for: s.ownerId),
                                           avatarBase64: avatar(for: s.ownerId), size: 36)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(name(for: s.ownerId)).font(.subheadline.weight(.medium)).lineLimit(1)
                                    HStack(spacing: 4) {
                                        if s.precision == "place" {
                                            Image(systemName: "mappin.circle.fill").font(.system(size: 9))
                                            Text(s.placeName.map { "At \($0)" } ?? "At a place").font(.caption2)
                                        } else {
                                            Image(systemName: st.activity.symbol).font(.system(size: 9))
                                            Text(s.precision == "approx" ? "~ \(st.line)" : st.line).font(.caption2)
                                        }
                                        if let b = st.battery.text {
                                            Text("· \(b)").font(.caption2)
                                                .foregroundStyle(st.battery.isLow ? .red : .secondary)
                                        }
                                    }
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(selected == s.id ? Color.accentColor.opacity(0.15) : .clear, in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
            }
            .padding(.vertical, 8).background(.thinMaterial, in: .capsule)
            .padding(.horizontal, 8).padding(.bottom, 12)
        }
    }
}

/// Map style choices (the floating toggle).
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

/// A sharer's map pin: avatar in a white-ringed circle with a pointer, accent
/// ring + lift when selected. The Life360-style member pin.
struct AvatarPin: View {
    let id: UUID
    let name: String
    let avatar: String?
    var selected: Bool = false
    var tempText: String? = nil   // weather-pin toggle overlays the temp

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                TraxAvatar(id: id, name: name, avatarBase64: avatar, size: selected ? 48 : 40)
                    .overlay(Circle().stroke(selected ? Color.accentColor : .white, lineWidth: 3))
                    .background(Circle().fill(.white).padding(-1))
                    .shadow(radius: 3, y: 1)
                if let t = tempText {
                    Text(t)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.thinMaterial, in: .capsule)
                        .overlay(Capsule().stroke(.white, lineWidth: 1))
                        .offset(x: 10, y: -6)
                }
            }
            Image(systemName: "triangle.fill")
                .font(.system(size: 9))
                .rotationEffect(.degrees(180))
                .foregroundStyle(selected ? Color.accentColor : .white)
                .offset(y: -2)
        }
        .animation(.spring(duration: 0.25), value: selected)
    }
}

/// Push target for a friend's full timeline (Identifiable + Hashable for navigationDestination).
struct HistoryTarget: Identifiable, Hashable {
    let ownerId: UUID
    let name: String
    var id: UUID { ownerId }
}

/// Push target for a friend's full forecast (coords carried so the screen needs
/// no map state; Hashable for navigationDestination).
struct WeatherTarget: Identifiable, Hashable {
    let ownerId: UUID
    let name: String
    let lat: Double
    let lng: Double
    var id: UUID { ownerId }
}

/// A snapshot of a sharer for the detail card (status evaluated at open).
struct MemberCard: Identifiable {
    let id: UUID          // share id
    let ownerId: UUID
    let name: String
    let avatar: String?
    let status: TraxMemberStatus
    let coordinate: CLLocationCoordinate2D
}

