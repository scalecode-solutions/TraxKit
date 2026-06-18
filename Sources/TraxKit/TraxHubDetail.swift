import SwiftUI
import MapKit
import CoreLocation

// In-panel detail for a tapped person — self or peer. Same visual stack; only the
// data source + actions differ. Replaces the old detented member sheet (Tangle's
// model: the hub map/controls stay put, only the panel content swaps to detail).

struct TraxHubDetailContent: View {
    let person: TraxPerson
    let sync: TraxSync
    let weather: TraxWeatherStore
    let geocoder: TraxGeocoder
    let selfCoordinate: CLLocationCoordinate2D?
    let myPlaces: [PlaceEntity]
    let onShare: () -> Void
    let onWeather: () -> Void
    let onHistory: () -> Void

    private var transitions: [TransitionDTO] {
        sync.recentTransitions.filter { $0.ownerId == person.ownerId }.prefix(5).map { $0 }
    }

    var body: some View {
        VStack(spacing: 16) {
            personCard.padding(.horizontal, 16)
            actionRow.padding(.horizontal, 16)
            activitySection
            weatherMini.padding(.horizontal, 16)
            if person.isSelf { placesSection }
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
                    Text(person.displayName).font(.system(size: 22, weight: .bold))
                    Text([label, person.secondary].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                TraxBatteryPill(battery: person.battery)
            }
            if !person.isSelf, let d = distanceText {
                HStack(spacing: 6) {
                    Image(systemName: "ruler").font(.caption)
                    Text(d).font(.system(size: 14))
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
            if person.isSelf {
                actionButton("Share", "person.crop.circle.badge.plus", disabled: false, action: onShare)
                actionButton("Check In", "checkmark.seal.fill", disabled: true) {}   // stubbed until it works right
            } else {
                actionButton("Directions", "arrow.triangle.turn.up.right.diamond.fill", disabled: false) {
                    openInMaps()
                }
                actionButton("Message", "bubble.left.fill", disabled: true) {}        // no messaging in standalone
            }
        }
    }

    private func actionButton(_ title: String, _ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(disabled ? Color.secondary : Color.primary)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Color.accentColor.opacity(disabled ? 0.04 : 0.12), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain).disabled(disabled)
    }

    private func openInMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: person.coordinate))
        item.name = person.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    // MARK: activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("RECENT ACTIVITY")
            if transitions.isEmpty {
                Text("Nothing recent.").font(.system(size: 14)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            } else {
                ForEach(transitions) { t in
                    HStack(spacing: 12) {
                        Circle().fill(.secondary.opacity(0.4)).frame(width: 8, height: 8)
                        Text("\(t.event == "enter" ? "Arrived at" : "Left") \(t.placeEmoji.map { "\($0) " } ?? "")\(t.placeName)")
                            .font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Text("· \(Self.relative(t.createdAt))").font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5).padding(.horizontal, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: weather mini

    private var weatherMini: some View {
        Button(action: onWeather) {
            HStack(spacing: 12) {
                TraxWeatherBadge(store: weather, latitude: person.coordinate.latitude,
                                 longitude: person.coordinate.longitude, showCondition: true)
                    .font(.title3)
                Spacer()
                Image(systemName: "chevron.forward").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: self places

    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("PLACES")
            if myPlaces.isEmpty {
                Text("No saved places.").font(.system(size: 14)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(myPlaces) { p in
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
        Text(s).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 20)
    }

    private static func relative(_ ms: Int64) -> String {
        let secs = Int(Date().timeIntervalSince1970 - Double(ms) / 1000)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
}
