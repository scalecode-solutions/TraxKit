import SwiftUI
import CoreLocation

// People pieces for the hub: the unified self/peer subject, the list row, the map
// pins, and the small battery pill. Self and sharers share one shape (Tangle's
// model) so "you" is the first row, not a separate tab.

/// One row/pin subject in the hub — self or a sharer, unified.
struct TraxPerson: Identifiable {
    let id: String              // "self" or share.id
    let ownerId: UUID
    let name: String
    let avatar: String?
    let coordinate: CLLocationCoordinate2D
    let isSelf: Bool
    let precision: String       // exact | place | approx
    let status: TraxMemberStatus?   // peer telemetry status; nil for self
    let battery: TraxBatteryStatus
    let placeName: String?
    let placeEmoji: String?
    let atPlace: Bool
    let fuzzRadiusM: Double?

    var exactGeocode: Bool { precision == "exact" }

    /// Instant label (no geocode): place name, else status line, else generic.
    var fallbackLabel: String {
        if atPlace, let n = placeName { return "At \(n)" }
        if precision == "approx" { return "Approximate area" }
        return status?.line ?? (isSelf ? "Here" : "Location shared")
    }

    /// Secondary line under the label: freshness / "you".
    var secondary: String? {
        if isSelf { return battery.text == nil ? nil : "You" }
        guard let s = status else { return nil }
        return s.isStale ? "Not updating" : s.lastUpdated
    }
}

// MARK: - People content (panel body for the People pill)

struct TraxHubPeopleContent: View {
    let people: [TraxPerson]
    let geocoder: TraxGeocoder
    let onTap: (TraxPerson) -> Void

    var body: some View {
        if people.isEmpty {
            TraxHubPeopleEmpty()
        } else {
            ForEach(people) { person in
                TraxPersonRow(person: person, geocoder: geocoder) { onTap(person) }
                if person.id != people.last?.id {
                    Divider().padding(.leading, 80)
                }
            }
        }
    }
}

struct TraxHubPeopleEmpty: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text("No one is sharing with you yet.").font(.subheadline.weight(.semibold))
            Text("They'll show up here when they do.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 32).padding(.horizontal, 24)
    }
}

// MARK: - Person row

struct TraxPersonRow: View {
    let person: TraxPerson
    let geocoder: TraxGeocoder
    let onTap: () -> Void

    private var label: String {
        if person.atPlace, let n = person.placeName { return "At \(n)" }
        if let g = geocoder.cachedLabel(latitude: person.coordinate.latitude,
                                        longitude: person.coordinate.longitude,
                                        exact: person.exactGeocode) {
            return person.precision == "approx" ? "~ \(g)" : g
        }
        return person.fallbackLabel
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    TraxAvatar(id: person.ownerId, name: person.name, avatarBase64: person.avatar, size: 52)
                    if person.battery.text != nil {
                        TraxBatteryPill(battery: person.battery).offset(x: -4, y: 6)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name).font(.system(size: 17, weight: .bold))
                    Text(label).font(.system(size: 14)).foregroundStyle(.primary.opacity(0.85)).lineLimit(1)
                    if let sec = person.secondary {
                        Text(sec).font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: "\(Int(person.coordinate.latitude * 1000)),\(Int(person.coordinate.longitude * 1000))") {
            if !person.atPlace {
                await geocoder.resolve(latitude: person.coordinate.latitude,
                                       longitude: person.coordinate.longitude,
                                       exact: person.exactGeocode)
            }
        }
    }
}

// MARK: - Battery pill

struct TraxBatteryPill: View {
    let battery: TraxBatteryStatus

    var body: some View {
        if let pct = battery.level {
            HStack(spacing: 2) {
                Image(systemName: battery.charging ? "battery.100.bolt" : Self.icon(pct))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(battery.isLow ? .red : .green)
                Text("\(pct)%").font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.ultraThinMaterial, in: .capsule)
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    static func icon(_ pct: Int) -> String {
        switch pct {
        case 76...:   "battery.100"
        case 51...75: "battery.75"
        case 26...50: "battery.50"
        case 11...25: "battery.25"
        default:      "battery.0"
        }
    }
}

// MARK: - Map pins

/// A sharer/self map pin: avatar in a white-ringed circle with a pointer, accent
/// ring + lift when selected, optional weather temp badge.
struct AvatarPin: View {
    let id: UUID
    let name: String
    let avatar: String?
    var selected: Bool = false
    var tempText: String? = nil

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
                .font(.system(size: 9)).rotationEffect(.degrees(180))
                .foregroundStyle(selected ? Color.accentColor : .white).offset(y: -2)
        }
        .animation(.spring(duration: 0.25), value: selected)
    }
}
