import SwiftUI

// Weather pill pane: a My Weather / Shared-with-me segment, mirroring Tangle. My
// Weather shows your current conditions; Shared lists each sharer's weather at
// their (precision-respecting) location. Tap a row to focus the map / open the
// full Tier-2 forecast.

enum TraxWeatherPage: String, CaseIterable, Identifiable {
    case mine, shared
    var id: Self { self }
    var label: String { self == .mine ? "My Weather" : "Shared with Me" }
}

struct TraxHubWeatherContent: View {
    let selfPerson: TraxPerson?
    let peers: [TraxPerson]
    let weather: TraxWeatherStore
    @Binding var page: TraxWeatherPage
    let onForecast: (TraxPerson) -> Void
    let onFocus: (TraxPerson) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Picker("Weather", selection: $page) {
                ForEach(TraxWeatherPage.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            switch page {
            case .mine:
                if let me = selfPerson {
                    row(me, focusable: false)
                } else {
                    Text("Waiting for your location…").font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            case .shared:
                if peers.isEmpty {
                    Text("No one is sharing with you yet.").font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    ForEach(peers) { row($0, focusable: true) }
                }
            }
        }
    }

    private func row(_ person: TraxPerson, focusable: Bool) -> some View {
        Button { onForecast(person) } label: {
            HStack(spacing: 12) {
                TraxAvatar(id: person.ownerId, name: person.name, avatarBase64: person.avatar, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(person.displayName).font(.system(size: 16, weight: .semibold))
                    TraxWeatherBadge(store: weather, latitude: person.coordinate.latitude,
                                     longitude: person.coordinate.longitude, showCondition: true)
                        .font(.subheadline)
                }
                Spacer()
                if focusable {
                    Button { onFocus(person) } label: {
                        Image(systemName: "scope").font(.title3).foregroundStyle(.secondary)
                            .frame(width: 40, height: 40).background(.ultraThinMaterial, in: .circle)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "chevron.forward").font(.footnote).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pure weather map pin (symbol + temp) for the Weather pill's map mode — no
/// avatar, glanceable conditions at each person's location.
struct TraxWeatherPin: View {
    let store: TraxWeatherStore
    let latitude: Double
    let longitude: Double

    var body: some View {
        Group {
            if let w = store.cached(latitude: latitude, longitude: longitude) {
                VStack(spacing: 1) {
                    Image(systemName: w.symbolName).symbolRenderingMode(.multicolor).font(.system(size: 18))
                    Text(w.tempText).font(.system(size: 13, weight: .bold))
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.thinMaterial, in: .capsule)
                .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                .shadow(radius: 2, y: 1)
            } else {
                Image(systemName: "cloud.fill").font(.title3).foregroundStyle(.secondary)
                    .padding(8).background(.thinMaterial, in: .circle)
            }
        }
        .task(id: "\(Int(latitude * 10)),\(Int(longitude * 10))") {
            await store.refresh(latitude: latitude, longitude: longitude)
        }
    }
}
