import SwiftUI

/// Tap-a-member glance card: status, battery, last-updated, latest arrival/leave,
/// and a "Location history" button that pushes their full timeline (Life360's
/// model — the glance is light; history is its own pushed screen, not crammed
/// into a detented sheet).
struct TraxMemberDetail: View {
    let card: MemberCard
    let sync: TraxSync
    let weather: TraxWeatherStore
    let onHistory: () -> Void

    private var latestTransition: TransitionDTO? {
        sync.recentTransitions.first { $0.ownerId == card.ownerId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                VStack(alignment: .trailing, spacing: 4) {
                    if let b = card.status.battery.text {
                        Label(b, systemImage: card.status.battery.charging ? "battery.100.bolt"
                              : (card.status.battery.isLow ? "battery.25" : "battery.100"))
                            .labelStyle(.titleAndIcon).font(.subheadline)
                            .foregroundStyle(card.status.battery.isLow ? .red : .secondary)
                    }
                    // Weather at their (presented) location.
                    TraxWeatherBadge(store: weather, latitude: card.coordinate.latitude,
                                     longitude: card.coordinate.longitude)
                        .font(.subheadline)
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

            Button(action: onHistory) {
                Label("Location history", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
