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

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selected: UUID?
    @State private var showShareSheet = false
    @State private var detail: MemberCard?

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

    /// Animate the camera onto a sharer when their marker is tapped/selected.
    private func focus(on id: UUID?) {
        guard let id, let coord = coordinate(of: id) else { return }
        withAnimation(.easeInOut) {
            camera = .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
        }
    }

    var body: some View {
        Map(position: $camera, selection: $selected) {
            UserAnnotation()   // the signed-in user's own blue dot
            ForEach(plottable) { s in
                Marker(name(for: s.ownerId),
                       coordinate: CLLocationCoordinate2D(latitude: s.lat ?? 0, longitude: s.lng ?? 0))
                    .tag(s.id)
            }
        }
        .onChange(of: selected) { _, new in focus(on: new) }
        .overlay(alignment: .top) {
            if let err = sync.lastError {
                Text(err).font(.caption).padding(8)
                    .background(.red.opacity(0.85), in: .capsule)
                    .foregroundStyle(.white).padding(.top, 8)
            }
        }
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
            TraxMemberDetail(card: c) { selected = c.id; focus(on: c.id) }
                .presentationDetents([.height(280), .medium])
        }
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
                        Button { detail = card(for: s); selected = s.id; focus(on: s.id) } label: {
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

/// A snapshot of a sharer for the detail card (status evaluated at open).
struct MemberCard: Identifiable {
    let id: UUID          // share id
    let ownerId: UUID
    let name: String
    let avatar: String?
    let status: TraxMemberStatus
    let coordinate: CLLocationCoordinate2D
}

/// Tap-a-member detail: avatar, name, status line, battery, last-updated, and a
/// "Show on map" action. Mirrors Life360's member card (minus the call/SOS
/// actions, which come with later pieces).
struct TraxMemberDetail: View {
    let card: MemberCard
    let onFocus: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                TraxAvatar(id: card.ownerId, name: card.name, avatarBase64: card.avatar, size: 56)
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
            }

            HStack(spacing: 10) {
                if let b = card.status.battery.text {
                    Label {
                        Text(b)
                    } icon: {
                        Image(systemName: card.status.battery.charging ? "battery.100.bolt"
                              : (card.status.battery.isLow ? "battery.25" : "battery.100"))
                    }
                    .font(.subheadline)
                    .foregroundStyle(card.status.battery.isLow ? .red : .primary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.quaternary, in: .capsule)
                }
                Spacer()
                Button { onFocus(); dismiss() } label: {
                    Label("Show on map", systemImage: "scope")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .presentationDragIndicator(.visible)
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
