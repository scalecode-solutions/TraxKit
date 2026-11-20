import SwiftUI
import MapKit
import CoreLocation

// In-panel detail for a tapped friend (self opens TraxMeView instead, from
// TraxHub's panelContent). Same visual stack; only the
// data source + actions differ. Replaces the old detented member sheet (the earlier version's
// model: the hub map/controls stay put, only the panel content swaps to detail).

struct TraxHubDetailContent: View {
    let person: TraxPerson
    let engine: TraxEngine
    let appearance: TraxAppearance
    let weather: TraxWeatherStore
    let geocoder: TraxGeocoder
    let selfCoordinate: CLLocationCoordinate2D?
    let onWeather: () -> Void
    let onHistory: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            personCard.padding(.horizontal, 16)
            actionRow.padding(.horizontal, 16)
            // My share to them, our places, their arrivals: the same content as
            // their person map's card (one implementation; arrivals share-gated
            // and durable). The header above stands in for its status line.
            TraxPersonCardContent(engine: engine, personID: person.ownerId, appearance: appearance, showsStatus: false)
                .padding(.horizontal, 16)
            weatherMini.padding(.horizontal, 16)
            historyButton.padding(.horizontal, 16)
            Color.clear.frame(height: 16)
        }
        .padding(.top, 8)
    }

    // MARK: card

    private var label: String {
        if person.atPlace, let n = person.placeName { return "At \(n)" }
        if let g = geocoder.cachedLabel(latitude: person.coordinate.latitude,
                                        longitude: person.coordinate.longitude,
                                        exact: person.exactGeocode) {
            return person.precision == "approx" ? "~ \(g)" : g
        }
        return person.fallbackLabel
    }

    private var personCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                TraxAvatar(id: person.ownerId, name: person.name, avatarBase64: person.avatar, size: 62)
                VStack(alignment: .leading, spacing: 3) {
                    Text(person.displayName).font(.system(.title2, weight: .bold))
                    Text([label, person.secondary].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(.subheadline)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                TraxBatteryPill(battery: person.battery)
            }
            if let d = distanceText {
                HStack(spacing: 6) {
                    Image(systemName: "ruler").font(.caption)
                    Text(d).font(.system(.subheadline))
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }

    private var distanceText: String? {
        guard let mine = selfCoordinate else { return nil }
        let meters = CLLocation(latitude: mine.latitude, longitude: mine.longitude)
            .distance(from: CLLocation(latitude: person.coordinate.latitude, longitude: person.coordinate.longitude))
        let miles = meters / 1609.344
        if miles < 0.1 { return "Right here" }
        if miles < 10 { return String(format: "%.1f mi away", miles) }
        return String(format: "%.0f mi away", miles)
    }

    // MARK: actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            actionButton("Directions", "arrow.triangle.turn.up.right.diamond.fill", disabled: false) {
                openInMaps()
            }
            // No disabled stubs (Check In, Message): a control that can't do
            // anything isn't shown.
        }
    }

    private func actionButton(_ title: String, _ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                Text(title).font(.system(.subheadline, weight: .semibold))
            }
            .foregroundStyle(disabled ? Color.secondary : Color.primary)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(.tint.opacity(disabled ? 0.04 : 0.12), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain).disabled(disabled)
    }

    private func openInMaps() {
        let c = person.coordinate
        let item = MKMapItem(location: CLLocation(latitude: c.latitude, longitude: c.longitude), address: nil)
        item.name = person.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    // MARK: weather mini

    /// Shown once there's weather to show; until then nothing (not an empty
    /// row), while the fetch still runs so it appears when it lands.
    @ViewBuilder private var weatherMini: some View {
        let lat = person.coordinate.latitude, lng = person.coordinate.longitude
        if weather.cached(latitude: lat, longitude: lng) != nil {
            weatherRow
        } else {
            Color.clear.frame(height: 0)
                .task(id: TraxWeatherStore.regionKey(latitude: lat, longitude: lng)) {
                    await weather.refresh(latitude: lat, longitude: lng)
                }
        }
    }

    private var weatherRow: some View {
        Button(action: onWeather) {
            HStack(spacing: 12) {
                TraxWeatherBadge(store: weather, latitude: person.coordinate.latitude,
                                 longitude: person.coordinate.longitude, showCondition: true)
                    .font(.title3)
                Spacer()
                Image(systemName: "chevron.forward").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.tint.opacity(0.06), in: .rect(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: self places

    private var historyButton: some View {
        Button(action: onHistory) {
            Label("Location history", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity)
        }
        .traxSecondaryAction()
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.system(.caption, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 20)
    }

}
