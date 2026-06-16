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
    public init(sync: TraxSync) { self.sync = sync }
    public var body: some View { TraxMapScreen(sync: sync) }
}

struct TraxMapScreen: View {
    let sync: TraxSync

    @Query(sort: \ShareEntity.updatedAt, order: .reverse) private var incoming: [ShareEntity]
    @Query(sort: \ContactEntity.name) private var contacts: [ContactEntity]
    @Query private var places: [PlaceEntity]

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selected: UUID?
    @State private var showShareSheet = false
    @State private var detail: MemberCard?
    @State private var detailDetent: PresentationDetent = .medium
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

    /// The selected sharer's breadcrumb, chronological, for the trail polyline.
    private var trailCoords: [CLLocationCoordinate2D] {
        sync.selectedTrail.sorted { $0.recordedAt < $1.recordedAt }
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
    }

    /// On selection change: open the member card (which loads their journeys) and
    /// focus the camera. No trail until a journey is picked.
    private func onSelect(_ id: UUID?) {
        focus(on: id)
        if let id, let sh = plottable.first(where: { $0.id == id }) {
            detail = card(for: sh)
            detailDetent = .medium
            sync.clearTrail()
            following = sh.ownerId   // follow their live position
        } else {
            detail = nil
            following = nil
            sync.clearMember()
        }
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

    /// A journey was tapped in the card: drop the card to a peek, draw that
    /// journey on the map (a trip's path / a visit's spot), frame it.
    private func onJourney(_ ownerID: UUID, _ item: TimelineItem) {
        detailDetent = .height(150)
        following = nil   // a journey is being framed — stop live-follow
        switch item {
        case .trip(let t):
            Task {
                await sync.loadTrail(ownerID: ownerID, since: t.startTs, before: t.endTs)
                fitTrail()
            }
        case .visit(let v):
            sync.clearTrail()
            focusCoord(CLLocationCoordinate2D(latitude: v.lat, longitude: v.lng), span: 0.01)
        }
    }

    /// Frame the camera to the current journey trail.
    private func fitTrail() {
        let cs = trailCoords
        guard !cs.isEmpty else { return }
        let lats = cs.map(\.latitude), lngs = cs.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                            longitude: (lngs.min()! + lngs.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.005, (lats.max()! - lats.min()!) * 1.5),
                                    longitudeDelta: max(0.005, (lngs.max()! - lngs.min()!) * 1.5))
        withAnimation(.easeInOut) { camera = .region(MKCoordinateRegion(center: center, span: span)) }
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

    var body: some View {
        Map(position: $camera, selection: $selected) {
            UserAnnotation()   // the signed-in user's own blue dot
            // Selected sharer's recent trail.
            if trailCoords.count > 1 {
                MapPolyline(coordinates: trailCoords)
                    .stroke(Color.accentColor.opacity(0.7),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            // Own saved places — muted context pins.
            ForEach(places) { p in
                Marker(p.name, monogram: Text(p.emoji ?? "📍"),
                       coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng))
                    .tint(.secondary)
            }
            // Sharers — avatar pins (Life360 feel).
            ForEach(plottable) { s in
                Annotation(name(for: s.ownerId),
                           coordinate: CLLocationCoordinate2D(latitude: s.lat ?? 0, longitude: s.lng ?? 0)) {
                    AvatarPin(id: s.ownerId, name: name(for: s.ownerId),
                              avatar: avatar(for: s.ownerId), selected: selected == s.id)
                }
                .tag(s.id)
            }
        }
        .mapStyle(style.style)
        .onMapCameraChange(frequency: .onEnd) { ctx in lastSpan = ctx.region.span }
        .onChange(of: selected) { _, new in onSelect(new) }
        .onChange(of: followKey) { _, _ in followRecenter() }
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
            TraxMemberDetail(card: c, sync: sync) { item in onJourney(c.ownerId, item) }
                .presentationDetents([.height(150), .medium, .large], selection: $detailDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
        .onChange(of: detail?.id) { _, id in
            if id == nil { selected = nil; sync.clearMember() }  // card dismissed
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
                                        Image(systemName: st.activity.symbol).font(.system(size: 9))
                                        Text(st.line).font(.caption2)
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

    var body: some View {
        VStack(spacing: 0) {
            TraxAvatar(id: id, name: name, avatarBase64: avatar, size: selected ? 48 : 40)
                .overlay(Circle().stroke(selected ? Color.accentColor : .white, lineWidth: 3))
                .background(Circle().fill(.white).padding(-1))
                .shadow(radius: 3, y: 1)
            Image(systemName: "triangle.fill")
                .font(.system(size: 9))
                .rotationEffect(.degrees(180))
                .foregroundStyle(selected ? Color.accentColor : .white)
                .offset(y: -2)
        }
        .animation(.spring(duration: 0.25), value: selected)
    }
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

/// Tap-a-member card: status header + the friend's journeys today (trips +
/// visits). Tapping a journey draws it on the map (parent handles via onJourney)
/// — Life360's "see each journey and its trail." Journeys are share-gated server
/// side. The header is always visible; the journey list scrolls at taller detents.
struct TraxMemberDetail: View {
    let card: MemberCard
    let sync: TraxSync
    let onJourney: (TimelineItem) -> Void

    /// The friend's journeys, most recent first.
    private var items: [TimelineItem] {
        let t = sync.memberTrips.map { TimelineItem.trip($0) }
        let v = sync.memberVisits.map { TimelineItem.visit($0) }
        return (t + v).sorted { $0.startTs > $1.startTs }
    }
    private var latestTransition: TransitionDTO? {
        sync.recentTransitions.first { $0.ownerId == card.ownerId }
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(20)
            Divider()
            journeys
        }
        .task(id: card.ownerId) { await sync.loadMemberTimeline(ownerID: card.ownerId) }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                TraxAvatar(id: card.ownerId, name: card.name, avatarBase64: card.avatar, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.name).font(.title3.weight(.semibold))
                    HStack(spacing: 5) {
                        Image(systemName: card.status.activity.symbol).font(.caption)
                        Text(card.status.line).font(.subheadline)
                    }
                    .foregroundStyle(card.status.isStale ? .secondary : .primary)
                    Text(card.status.lastUpdated).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let b = card.status.battery.text {
                    Label(b, systemImage: card.status.battery.charging ? "battery.100.bolt"
                          : (card.status.battery.isLow ? "battery.25" : "battery.100"))
                        .labelStyle(.titleAndIcon).font(.subheadline)
                        .foregroundStyle(card.status.battery.isLow ? .red : .secondary)
                }
            }
            if let latest = latestTransition {
                HStack(spacing: 6) {
                    Image(systemName: latest.event == "enter" ? "arrow.down.to.line.compact" : "arrow.up.from.line.compact")
                    Text("\(latest.event == "enter" ? "Arrived at" : "Left") \(latest.placeEmoji ?? "") \(latest.placeName)")
                        .font(.footnote)
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var journeys: some View {
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "clock").font(.title3).foregroundStyle(.secondary)
                Text("No journeys today").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.top, 28)
            Spacer()
        } else {
            List(items) { item in
                Button { onJourney(item) } label: { JourneyRow(item: item) }
                    .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}

/// A compact journey row in the member card (a trip or a dwell).
struct JourneyRow: View {
    let item: TimelineItem

    var body: some View {
        switch item {
        case .visit(let v):
            row(emoji: v.placeEmoji ?? "📍", color: .accentColor,
                title: v.placeName ?? "Stop",
                detail: "\(timeRange(v.startTs, v.endTs)) · \(durationText(v.durationSeconds))")
        case .trip(let t):
            HStack(spacing: 12) {
                Image(systemName: motionSymbol(t.motionType)).font(.body)
                    .frame(width: 32, height: 32)
                    .background(motionColor(t.motionType).opacity(0.18), in: .circle)
                    .foregroundStyle(motionColor(t.motionType))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(t.startPlaceName ?? "Start") → \(t.endPlaceName ?? "End")").font(.subheadline)
                    Text("\(timeRange(t.startTs, t.endTs)) · \(distanceText(t.distanceMeters))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func row(emoji: String, color: Color, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Text(emoji).font(.title3).frame(width: 32, height: 32).background(color.opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func motionSymbol(_ m: String?) -> String {
        switch m { case "automotive": "car.fill"; case "cycling": "bicycle"
        case "running": "figure.run"; case "walking": "figure.walk"; default: "arrow.right" }
    }
    private func motionColor(_ m: String?) -> Color {
        switch m { case "automotive": .orange; case "cycling": .green
        case "running": .red; case "walking": .blue; default: .gray }
    }
    private func timeRange(_ a: Int64, _ b: Int64) -> String {
        let f = Date.FormatStyle.dateTime.hour().minute()
        return "\(Date(timeIntervalSince1970: Double(a)/1000).formatted(f))–\(Date(timeIntervalSince1970: Double(b)/1000).formatted(f))"
    }
    private func durationText(_ s: Int) -> String { s < 3600 ? "\(s/60)m" : "\(s/3600)h \((s%3600)/60)m" }
    private func distanceText(_ m: Double) -> String {
        let mi = m / 1609.34; return mi < 0.1 ? "\(Int(m)) m" : String(format: "%.1f mi", mi)
    }
}

/// Pick a friend + duration to start sharing; manage active outgoing shares.
struct TraxShareSheet: View {
    let sync: TraxSync

    @Query(sort: \ContactEntity.name) private var contacts: [ContactEntity]
    @Environment(\.dismiss) private var dismiss

    @State private var duration: ShareDuration = .fifteenMinutes
    @State private var busy: UUID?
    @State private var error: String?

    private var sharingViewerIDs: Set<UUID> { Set(sync.outgoing.map(\.viewerId)) }
    private func contactName(_ id: UUID) -> String {
        contacts.first { $0.id == id }?.name ?? "Member \(id.uuidString.prefix(8))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Duration") {
                    Picker("Duration", selection: $duration) {
                        ForEach(ShareDuration.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if !sync.outgoing.isEmpty {
                    Section("Sharing with") {
                        ForEach(sync.outgoing) { share in
                            HStack {
                                Text(contactName(share.viewerId))
                                Spacer()
                                Button("Stop", role: .destructive) { stop(share.id) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section("Friends") {
                    if contacts.isEmpty {
                        Text("No contacts synced yet").foregroundStyle(.secondary)
                    }
                    ForEach(contacts) { c in
                        Button { start(with: c.id) } label: {
                            HStack {
                                Text(c.name.isEmpty ? "Member \(c.id.uuidString.prefix(8))" : c.name)
                                Spacer()
                                if busy == c.id { ProgressView() }
                                else if sharingViewerIDs.contains(c.id) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                        }
                        .disabled(sharingViewerIDs.contains(c.id) || busy != nil)
                    }
                }

                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("Share location")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func start(with viewer: UUID) {
        busy = viewer; error = nil
        Task {
            defer { busy = nil }
            do { _ = try await sync.startShare(viewer: viewer, expiresInSeconds: duration.expiresInSeconds) }
            catch { self.error = describe(error) }
        }
    }

    private func stop(_ id: UUID) {
        Task {
            do { try await sync.stopShare(id: id) } catch { self.error = describe(error) }
        }
    }

    private func describe(_ e: Error) -> String {
        if let te = e as? TraxError { return te.message }
        return String(describing: e)
    }
}
