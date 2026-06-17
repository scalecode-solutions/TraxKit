import SwiftUI
import SwiftData
import CoreLocation

/// The "Me" tab: own identity, who I'm sharing with (+ stop controls), and
/// sharing/privacy settings. Composable piece hosted in the Me tab.
///
/// Own identity + outgoing-share management are live; sharing defaults,
/// retention, permissions, and history land here as those pieces are built.
public struct TraxSettingsView: View {
    let sync: TraxSync
    let weather: TraxWeatherStore
    let onSignOut: (() -> Void)?

    @Query(sort: \ContactEntity.name) private var contacts: [ContactEntity]
    @State private var me: TraxContact?
    @State private var selfCoord: CLLocationCoordinate2D?
    @State private var stoppingAll = false
    private let locator = CLLocationManager()

    public init(sync: TraxSync, weather: TraxWeatherStore, onSignOut: (() -> Void)? = nil) {
        self.sync = sync
        self.weather = weather
        self.onSignOut = onSignOut
    }

    private func name(_ id: UUID) -> String {
        contacts.first { $0.id == id }?.name ?? "Member \(id.uuidString.prefix(8))"
    }
    private func avatar(_ id: UUID) -> String? { contacts.first { $0.id == id }?.avatar }

    public var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    TraxAvatar(id: me?.id, name: me?.name, avatarBase64: me?.avatar, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(me?.name ?? "You").font(.headline)
                        Text("Signed in").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let c = selfCoord {
                        TraxWeatherBadge(store: weather, latitude: c.latitude, longitude: c.longitude,
                                         showCondition: false).font(.title3)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Sharing with") {
                if sync.outgoing.isEmpty {
                    Text("You're not sharing your location with anyone.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sync.outgoing) { share in
                        HStack(spacing: 12) {
                            TraxAvatar(id: share.viewerId, name: name(share.viewerId),
                                       avatarBase64: avatar(share.viewerId), size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name(share.viewerId))
                                Text(share.mode == "breadcrumb" ? "Breadcrumb" : "Live")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Stop", role: .destructive) { stop(share.id) }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button(role: .destructive) { stopAll() } label: {
                        if stoppingAll { ProgressView() } else { Text("Stop all sharing") }
                    }
                }
            }

            if let onSignOut {
                Section {
                    Button("Sign Out", role: .destructive) { onSignOut() }
                }
            }
        }
        .task {
            me = try? await sync.me()
            selfCoord = locator.location?.coordinate   // current fix for self weather
        }
    }

    private func stop(_ id: UUID) {
        Task { try? await sync.stopShare(id: id) }
    }
    private func stopAll() {
        stoppingAll = true
        Task { defer { stoppingAll = false }; try? await sync.stopAll() }
    }
}
