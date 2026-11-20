import SwiftUI

/// What the kit shows about one person, wherever it shows them: their status,
/// my share to them, the places we share, their recent arrivals. The person
/// map's card and the hub's person detail both use it, so the two never drift
/// (arrivals come from `recentTransitions(with:)`, the share-gated, durable
/// read, in both). The hub has its own header (avatar, place, battery,
/// distance), so it leaves the status out.
struct TraxPersonCardContent: View {
    let engine: TraxEngine
    let personID: UUID
    let appearance: TraxAppearance
    var showsStatus = true

    @State private var placeError: String?
    @Environment(\.traxDisplayNames) private var names

    private var name: String { names.name(for: personID, people: engine.people) }
    private var relationship: TraxRelationship { engine.relationship(with: personID) }
    private var summary: TraxLocationSummary? { relationship.incoming }
    private var places: [TraxSharedPlace] { engine.sharedPlaces(with: personID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsStatus {
                status
                Divider()
            }
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
