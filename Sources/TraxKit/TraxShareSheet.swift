import SwiftUI
import SwiftData

/// How much location a share reveals (maps to the server's precision tiers).
enum SharePrecision: String, CaseIterable, Identifiable {
    case exact, place, approx
    var id: Self { self }
    var label: String {
        switch self { case .exact: "Exact"; case .place: "Places"; case .approx: "Approx" }
    }
    var blurb: String {
        switch self {
        case .exact:  "Your live location, and they can see your trips & history."
        case .place:  "Only which saved place you're at (e.g. \"at Home\") — not your live dot."
        case .approx: "A fuzzed ~1 km area, not your exact spot."
        }
    }
}

/// Pick a friend + duration + precision to start sharing; manage active shares.
struct TraxShareSheet: View {
    let sync: TraxSync

    @Query(sort: \ContactEntity.name) private var contacts: [ContactEntity]
    @Environment(\.dismiss) private var dismiss

    @State private var duration: ShareDuration = .fifteenMinutes
    @State private var precision: SharePrecision = .exact
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

                Section {
                    Picker("Precision", selection: $precision) {
                        ForEach(SharePrecision.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Precision")
                } footer: {
                    Text(precision.blurb)
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
            do { _ = try await sync.startShare(viewer: viewer, precision: precision.rawValue, expiresInSeconds: duration.expiresInSeconds) }
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
