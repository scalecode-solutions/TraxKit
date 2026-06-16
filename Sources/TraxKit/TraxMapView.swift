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

/// The embedded TraxKit screen: a map of who's sharing their location with you,
/// plus the share controls. The host (TraxLab/Clingy) drops this in; TraxKit owns
/// the map + sheet. Pull-feed driven (HTTP poll) — no socket.
public struct TraxLocationView: View {
    private let config: TraxConfig
    private let store: TraxStore
    @State private var sync: TraxSync

    public init(config: TraxConfig, store: TraxStore) {
        self.config = config
        self.store = store
        _sync = State(initialValue: TraxSync(config: config, store: store))
    }

    public var body: some View {
        TraxMapScreen(sync: sync)
            .modelContainer(store.container)
    }
}

struct TraxMapScreen: View {
    let sync: TraxSync

    @Query(sort: \ShareEntity.updatedAt, order: .reverse) private var incoming: [ShareEntity]
    @Query(sort: \ContactEntity.name) private var contacts: [ContactEntity]

    @State private var camera: MapCameraPosition = .automatic
    @State private var showShareSheet = false

    private var contactsByID: [UUID: ContactEntity] {
        Dictionary(contacts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private var plottable: [ShareEntity] { incoming.filter(\.hasLocation) }

    func name(for id: UUID) -> String {
        let c = contactsByID[id]
        if let n = c?.name, !n.isEmpty { return n }
        return "Member \(id.uuidString.prefix(8))"
    }

    var body: some View {
        Map(position: $camera) {
            ForEach(plottable) { s in
                Marker(name(for: s.ownerId),
                       coordinate: CLLocationCoordinate2D(latitude: s.lat ?? 0, longitude: s.lng ?? 0))
            }
        }
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
        .task { await loop() }
    }

    @ViewBuilder private var peopleBar: some View {
        if plottable.isEmpty {
            Text(incoming.isEmpty ? "No one is sharing with you yet" : "Sharers located soon…")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(10).background(.thinMaterial, in: .capsule).padding(.bottom, 12)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(plottable) { s in
                        VStack(spacing: 2) {
                            Image(systemName: "mappin.circle.fill").font(.title2)
                            Text(name(for: s.ownerId)).font(.caption2).lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 8).background(.thinMaterial, in: .capsule).padding(.bottom, 12)
        }
    }

    /// Initial load + poll loop (5s). `.task` cancels on disappear.
    private func loop() async {
        await sync.loadContacts()
        await sync.refresh()
        await sync.refreshOutgoing()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { break }
            await sync.refresh()
            await sync.refreshOutgoing()
        }
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
