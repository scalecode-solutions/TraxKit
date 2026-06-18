import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// The rich "Me" surface (tapping your own row in People). Your glance + your
/// privacy control center: who can see you, at what precision, for how long —
/// with a per-viewer "what they see" preview, your recent activity, and places.
struct TraxMeView: View {
    let person: TraxPerson          // the synthesized self (displayName "Me", coord, battery, place)
    let sync: TraxSync
    let weather: TraxWeatherStore
    let geocoder: TraxGeocoder
    let onShare: () -> Void
    let onWeather: () -> Void
    let onHistory: () -> Void

    @Query(sort: \ContactEntity.name) private var contacts: [ContactEntity]
    @Query private var places: [PlaceEntity]

    @State private var activity: [ActivityItem] = []
    @State private var preview: PreviewTarget?
    @State private var stoppingAll = false

    private var coord: CLLocationCoordinate2D { person.coordinate }
    private func contact(_ id: UUID) -> ContactEntity? { contacts.first { $0.id == id } }
    private func viewerName(_ id: UUID) -> String {
        let n = contact(id)?.name
        return (n?.isEmpty == false ? n! : "Member \(id.uuidString.prefix(8))")
    }

    var body: some View {
        VStack(spacing: 16) {
            header.padding(.horizontal, 16)
            sharingSection
            activitySection
            placesSection
            historyButton.padding(.horizontal, 16)
            Color.clear.frame(height: 16)
        }
        .padding(.top, 8)
        .task(id: "\(Int(coord.latitude * 1000)),\(Int(coord.longitude * 1000))") {
            if !person.atPlace {
                await geocoder.resolve(latitude: coord.latitude, longitude: coord.longitude, exact: true)
            }
        }
        .task { await loadActivity() }
        .sheet(item: $preview) { t in
            SelfSharePreview(viewerName: t.name, precision: t.precision, coord: coord, places: places,
                             meId: person.ownerId, meName: person.name, meAvatar: person.avatar)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: header (glance)

    private var label: String {
        if person.atPlace, let n = person.placeName { return "At \(n)" }
        if let g = geocoder.cachedLabel(latitude: coord.latitude, longitude: coord.longitude, exact: true) { return g }
        return person.fallbackLabel
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                TraxAvatar(id: person.ownerId, name: person.name, avatarBase64: person.avatar, size: 62)
                TraxPresenceDot(live: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Me").font(.system(size: 22, weight: .bold))
                Text(label).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                TraxBatteryPill(battery: person.battery)
                Button(action: onWeather) {
                    TraxWeatherBadge(store: weather, latitude: coord.latitude, longitude: coord.longitude).font(.subheadline)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }

    // MARK: sharing control center

    private var sharingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("WHO CAN SEE ME")
            if sync.outgoing.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "eye.slash").font(.title2).foregroundStyle(.secondary)
                    Text("No one can see your location.").font(.subheadline.weight(.medium))
                    Text("You're invisible until you share.").font(.caption).foregroundStyle(.secondary)
                    Button(action: onShare) { Label("Share my location", systemImage: "person.crop.circle.badge.plus") }
                        .buttonStyle(.borderedProminent).padding(.top, 4)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(sync.outgoing) { shareRow($0) }
                }
                HStack(spacing: 10) {
                    Button(action: onShare) { Label("Add", systemImage: "plus").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                    Button(role: .destructive) { goInvisible() } label: {
                        if stoppingAll { ProgressView().frame(maxWidth: .infinity) }
                        else { Label("Go invisible", systemImage: "eye.slash").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shareRow(_ share: ShareDTO) -> some View {
        HStack(spacing: 12) {
            TraxAvatar(id: share.viewerId, name: viewerName(share.viewerId),
                       avatarBase64: contact(share.viewerId)?.avatar, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewerName(share.viewerId)).font(.system(size: 15, weight: .medium))
                Text(expiryText(share)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(SharePrecision.allCases) { p in
                    Button { changePrecision(share, to: p) } label: {
                        Label(p.label, systemImage: share.precision == p.rawValue ? "checkmark" : precisionIcon(p))
                    }
                }
            } label: { precisionChip(share.precision) }

            Button { preview = PreviewTarget(viewerId: share.viewerId, name: viewerName(share.viewerId), precision: share.precision) } label: {
                Image(systemName: "eye").font(.system(size: 15))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)

            Button { stop(share) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 18)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func precisionChip(_ raw: String) -> some View {
        let p = SharePrecision(rawValue: raw) ?? .exact
        return HStack(spacing: 3) {
            Image(systemName: precisionIcon(p)).font(.system(size: 10))
            Text(p.label).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.12), in: .capsule)
        .foregroundStyle(Color.accentColor)
    }

    private func precisionIcon(_ p: SharePrecision) -> String {
        switch p { case .exact: "scope"; case .place: "mappin.circle"; case .approx: "circle.dashed" }
    }

    private func expiryText(_ s: ShareDTO) -> String {
        guard let exp = s.expiresAt else { return "until you stop" }
        let secs = Int(Double(exp) / 1000 - Date().timeIntervalSince1970)
        if secs <= 0 { return "expiring…" }
        if secs < 3600 { return "for \(secs / 60)m more" }
        if secs < 86400 { return "for \(secs / 3600)h more" }
        return "for \(secs / 86400)d more"
    }

    private func changePrecision(_ s: ShareDTO, to p: SharePrecision) {
        guard s.precision != p.rawValue else { return }
        let remaining: Int? = s.expiresAt.map { Int(max(0, Double($0) / 1000 - Date().timeIntervalSince1970)) }
        Task { try? await sync.startShare(viewer: s.viewerId, precision: p.rawValue, expiresInSeconds: remaining) }
    }
    private func stop(_ s: ShareDTO) { Task { try? await sync.stopShare(id: s.id) } }
    private func goInvisible() { stoppingAll = true; Task { defer { stoppingAll = false }; try? await sync.stopAll() } }

    // MARK: activity (own timeline, today)

    private func loadActivity() async {
        let day = await sync.timeline(ownerID: person.ownerId, day: Date())
        var items: [ActivityItem] = []
        for v in day.visits {
            let name = v.placeName ?? "a spot"
            items.append(ActivityItem(icon: "mappin.circle.fill", text: "At \(name) · \(Self.dur(v.durationSeconds))",
                                      rel: Self.rel(v.startTs), ts: v.startTs))
        }
        for t in day.trips {
            items.append(ActivityItem(icon: Self.motionIcon(t.motionType), text: Self.tripText(t),
                                      rel: Self.rel(t.startTs), ts: t.startTs))
        }
        activity = items.sorted { $0.ts > $1.ts }.prefix(6).map { $0 }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("TODAY")
            if activity.isEmpty {
                Text("No movement logged yet today.").font(.system(size: 14)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            } else {
                ForEach(activity) { a in
                    HStack(spacing: 12) {
                        Image(systemName: a.icon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                        Text(a.text).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(a.rel).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5).padding(.horizontal, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: places + history

    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("MY PLACES")
            if places.isEmpty {
                Text("No saved places.").font(.system(size: 14)).foregroundStyle(.secondary).padding(.horizontal, 20)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(places.filter { $0.ownerId == person.ownerId }) { p in
                        HStack(spacing: 10) {
                            Text(p.emoji ?? "📍").font(.system(size: 22)).frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text("\(p.radiusM) m").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10).background(Color.accentColor.opacity(0.05), in: .rect(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historyButton: some View {
        Button(action: onHistory) {
            Label("Location history", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 20)
    }

    // MARK: formatting

    private static func dur(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(max(m, 1))m"
    }
    private static func rel(_ ms: Int64) -> String {
        let secs = Int(Date().timeIntervalSince1970 - Double(ms) / 1000)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
    private static func motionIcon(_ m: String?) -> String {
        switch m { case "automotive": "car.fill"; case "cycling": "bicycle"; case "running": "figure.run"; case "walking": "figure.walk"; default: "arrow.triangle.turn.up.right.diamond.fill" }
    }
    private static func tripText(_ t: TripDTO) -> String {
        let verb: String
        switch t.motionType { case "automotive": verb = "Drove"; case "cycling": verb = "Biked"; case "running": verb = "Ran"; case "walking": verb = "Walked"; default: verb = "Moved" }
        let mi = t.distanceMeters / 1609.344
        return mi < 0.1 ? "\(verb) nearby" : String(format: "%@ %.1f mi", verb, mi)
    }
}

/// Sheet target for the "what they see" preview.
struct PreviewTarget: Identifiable {
    let viewerId: UUID
    let name: String
    let precision: String
    var id: UUID { viewerId }
}

private struct ActivityItem: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let rel: String
    let ts: Int64
}

/// "What they see" — your CURRENT location rendered exactly as a viewer at the
/// given precision sees it (the same transform the server applies at read time),
/// so you can verify your own privacy.
struct SelfSharePreview: View {
    let viewerName: String
    let precision: String
    let coord: CLLocationCoordinate2D
    let places: [PlaceEntity]
    let meId: UUID
    let meName: String
    let meAvatar: String?

    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                caption.padding(16)
                if presented.hidden {
                    ContentUnavailableView("Hidden right now", systemImage: "eye.slash",
                                           description: Text("You're away from your saved places, so \(viewerName) sees nothing until you arrive at one."))
                } else {
                    map
                }
            }
            .navigationTitle("What \(viewerName) sees")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private var caption: some View {
        let p = SharePrecision(rawValue: precision) ?? .exact
        let line: String
        switch p {
        case .exact: line = "Your exact, live location."
        case .place: line = presented.place.map { "Only that you're at \($0) — not your live dot." } ?? "Only which saved place you're at."
        case .approx: line = "A fuzzed ~1 km area, not your exact spot."
        }
        return HStack(spacing: 8) {
            Image(systemName: p == .exact ? "scope" : (p == .place ? "mappin.circle" : "circle.dashed"))
                .foregroundStyle(Color.accentColor)
            Text(line).font(.subheadline)
            Spacer(minLength: 0)
        }
    }

    private var map: some View {
        Map(position: $camera) {
            if let c = presented.coord {
                if let fuzz = presented.fuzz {
                    MapCircle(center: c, radius: fuzz)
                        .foregroundStyle(Color.accentColor.opacity(0.15))
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                }
                if precision == "exact" {
                    Annotation("You", coordinate: c) { AvatarPin(id: meId, name: meName, avatar: meAvatar) }
                } else if let place = presented.place {
                    Marker(place, monogram: Text("📍"), coordinate: c).tint(Color.accentColor)
                } else {
                    Marker("~ Around here", coordinate: c).tint(Color.accentColor)
                }
            }
        }
        .onAppear {
            if let c = presented.coord {
                let span = presented.fuzz != nil ? 0.04 : (precision == "place" ? 0.02 : 0.006)
                camera = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
            }
        }
    }

    /// The same transform the server's applyPrecision uses, computed locally.
    private var presented: (coord: CLLocationCoordinate2D?, fuzz: Double?, place: String?, hidden: Bool) {
        switch precision {
        case "approx":
            let g = CLLocationCoordinate2D(latitude: Double(Int(coord.latitude * 100)) / 100,
                                           longitude: Double(Int(coord.longitude * 100)) / 100)
            return (g, 900, nil, false)
        case "place":
            if let p = places.first(where: { CLLocation(latitude: $0.lat, longitude: $0.lng)
                .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude)) <= Double($0.radiusM) }) {
                return (CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng), nil, p.name, false)
            }
            return (nil, nil, nil, true)
        default:
            return (coord, nil, nil, false)
        }
    }
}
