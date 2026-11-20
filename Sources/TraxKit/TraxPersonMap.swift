import SwiftUI
import MapKit

/// One person's map: where they are (if they share with me), our shared places,
/// and a card with their status, my share to them, our places and their recent
/// arrivals. Find My grammar: the map is the page, the controls sit on a card.
///
/// Layout notes (field-tested in a host app first):
/// - The card is a bottom SAFE-AREA INSET, not an overlay: MapKit frames the
///   camera inside the safe area, so the person stays in the visible strip
///   instead of under the card.
/// - The card scrolls and is capped to part of the screen, so at the largest
///   text it never pushes past the host's tab bar.
/// - Recenter hangs above the card from a zero-height anchor, so it doesn't
///   change the inset (and the camera frame) it sits on.
/// - The map follows the person on each update until the user pans; recenter
///   resumes following.
struct TraxPersonMap: View {
    let engine: TraxEngine
    let personID: UUID
    let appearance: TraxAppearance

    @State private var camera: MapCameraPosition = .automatic
    @State private var placeError: String?
    @ScaledMetric(relativeTo: .body) private var markerSize: CGFloat = 34
    @Environment(\.traxDisplayNames) private var names

    private var name: String { names.name(for: personID, people: engine.people) }
    private var avatar: String? { engine.people[personID]?.avatar }
    private var relationship: TraxRelationship { engine.relationship(with: personID) }
    private var summary: TraxLocationSummary? { relationship.incoming }
    private var places: [TraxSharedPlace] { engine.sharedPlaces(with: personID) }

    var body: some View {
        GeometryReader { geo in
            map
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    card(maxHeight: geo.size.height * 0.5)
                        .overlay(alignment: .topTrailing) {
                            if summary?.coordinate != nil {
                                recenterButton
                                    .padding(.trailing, 12).padding(.bottom, 12)
                                    .frame(height: 0, alignment: .bottom)
                            }
                        }
                }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: personID) { await engine.backfillTransitions(with: personID, limit: 50) }
        .onAppear { recenter(animated: false) }
        // The update time is the change signal; following stops once the user
        // pans (a programmatic camera isn't "positioned by user").
        .onChange(of: summary?.lastUpdatedMs) { _, _ in
            guard !camera.positionedByUser else { return }
            recenter(animated: true)
        }
    }

    // MARK: map

    private var map: some View {
        Map(position: $camera) {
            if let coord = summary?.coordinate {
                Annotation(name, coordinate: coord) { marker }
            }
            ForEach(places) { place in
                let center = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
                Marker(place.name, monogram: Text(place.emoji ?? "📍"), coordinate: center)
                    .tint(.tint.opacity(0.75))
                MapCircle(center: center, radius: CLLocationDistance(place.radiusM))
                    .foregroundStyle(.tint.opacity(0.08))
                    .stroke(.tint.opacity(0.3), lineWidth: 1)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        // No .ignoresSafeArea: the card's inset is what frames the camera.
        .accessibilityIdentifier("person.map")
    }

    private var marker: some View {
        TraxAvatar(id: personID, name: name, avatarBase64: avatar, size: markerSize)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
            .shadow(radius: 3)
            .overlay {
                if summary?.isLive == true {   // live: fresh fixes are arriving
                    Circle().strokeBorder(.tint.opacity(0.35), lineWidth: 2)
                        .frame(width: markerSize + 12, height: markerSize + 12)
                }
            }
    }

    private var recenterButton: some View {
        Button { recenter(animated: true) } label: {
            Image(systemName: "scope")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .traxGlass(in: .circle, interactive: true)
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel("Center on \(name)")
        .accessibilityIdentifier("person.recenter")
    }

    private func recenter(animated: Bool) {
        guard let coord = summary?.coordinate else { return }
        let region = MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        if animated { withAnimation(.easeInOut(duration: 0.6)) { camera = .region(region) } }
        else { camera = .region(region) }
    }

    // MARK: card

    private func card(maxHeight: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                status
                Divider()
                TraxShareControls(engine: engine, personID: personID, personName: name, appearance: appearance)
                if !places.isEmpty {
                    Divider()
                    placesSection
                }
                let recent = engine.recentTransitions(with: personID, limit: 5)
                if !recent.isEmpty {
                    Divider()
                    recentSection(recent)
                }
            }
            .padding(18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        // The card is laid out above the bottom safe area (the inset frames
        // the camera) and its scroll stays there, so the last row rests above
        // the home indicator or a host's tab bar on every iOS: a scroll view
        // run into the safe area gets the automatic content inset on iOS 26
        // but not on iOS 27, which slid the content under the tab bar and left
        // empty glass at the top (MVTRAX-39). Only the glass is drawn on to
        // the screen's edge, so no strip of map shows below the card.
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)
                .fill(.clear)
                .traxGlass(in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .accessibilityIdentifier("person.card")
    }

    private var status: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                statusText
                Spacer(minLength: 8)
                weather
            }
            VStack(alignment: .leading, spacing: 6) {
                statusText
                weather
            }
        }
    }

    private var statusText: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(headline).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("person.status")
            HStack(spacing: 8) {
                if let s = summary, s.lastUpdatedMs != nil {
                    // The same wording as the hub: "Not updating" only for an
                    // exact share, and no minute-level time for an approximate one.
                    Text(TraxMemberStatus.make(speedMps: nil, motion: nil, batteryLevel: nil, batteryCharging: false,
                                               recordedAtMs: s.lastUpdatedMs, precision: s.precision).lastUpdated)
                        .accessibilityIdentifier("person.updated")
                }
                if let battery = summary?.battery {
                    Label("\(battery)%", systemImage: batterySymbol(battery, charging: summary?.batteryCharging == true))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var weather: some View {
        if let coord = summary?.coordinate {
            // An accessory to the status: nothing until there's weather.
            TraxWeatherBadge(store: engine.weather, latitude: coord.latitude, longitude: coord.longitude, showCondition: true)
                .quietWhenEmpty()
                .font(.subheadline)
        }
    }

    private var headline: String {
        guard let summary else { return appearance.with(appearance.notSharing, name) }
        if summary.atPlace, let place = summary.placeName { return "At \(place)" }
        if summary.coordinate != nil { return summary.isLive ? "Live location" : "Last known location" }
        return "Away from shared places"   // a place-precision share, away from them
    }

    private func batterySymbol(_ level: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default:    return "battery.100percent"
        }
    }

    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appearance.with(appearance.placesTogether, name)).font(.subheadline.weight(.semibold))
            ForEach(places) { place in
                HStack {
                    Text("\(place.emoji.map { "\($0) " } ?? "")\(place.name)").font(.subheadline)
                    Spacer()
                    Button("Stop", role: .destructive) {
                        placeError = nil
                        Task {
                            do { try await engine.unsharePlace(place.id, with: personID) }
                            catch { placeError = "Couldn't stop sharing \(place.name). Try again." }
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(TraxPalette.destructive)
                    .frame(minHeight: 44)
                }
            }
            if let placeError {
                Text(placeError).font(.footnote).foregroundStyle(TraxPalette.destructive)
            }
        }
    }

    private func recentSection(_ items: [TransitionDTO]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent").font(.subheadline.weight(.semibold))
            ForEach(items) { t in
                ViewThatFits(in: .horizontal) {
                    HStack {
                        transitionLabel(t)
                        Spacer()
                        transitionTime(t)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        transitionLabel(t)
                        transitionTime(t)
                    }
                }
            }
        }
    }

    private func transitionLabel(_ t: TransitionDTO) -> some View {
        Label("\(t.event == "enter" ? "Arrived at" : "Left") \(t.placeEmoji.map { "\($0) " } ?? "")\(t.placeName)",
              systemImage: t.event == "enter" ? "arrow.down.right.circle" : "arrow.up.right.circle")
            .font(.subheadline)
    }

    private func transitionTime(_ t: TransitionDTO) -> some View {
        Text(traxCrossingTime(Date(timeIntervalSince1970: Double(t.createdAt) / 1000)))
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// When a crossing happened, as a short label: the time today, "Yesterday"
/// and the time, the weekday within a week, else the date (with the year
/// when it isn't this one). A time alone
/// would read as today for an arrival days old.
func traxCrossingTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDate(date, inSameDayAs: now) { return time }
    if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
        return "Yesterday \(time)"
    }
    if let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= week {
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
    return date.formatted(.dateTime.month(.abbreviated).day().year())
}
