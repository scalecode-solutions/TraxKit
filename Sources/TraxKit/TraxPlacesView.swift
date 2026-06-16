import SwiftUI
import SwiftData
import CoreLocation

/// Saved places (home/work/custom), shared with friends, with arrival/departure
/// alerts. Lists the user's places and lets them add/edit/delete. Hosted in the
/// Places tab.
public struct TraxPlacesView: View {
    let sync: TraxSync

    @Query(sort: \PlaceEntity.updatedAt, order: .reverse) private var places: [PlaceEntity]
    @State private var editing: PlaceEdit?
    @State private var error: String?

    public init(sync: TraxSync) { self.sync = sync }

    public var body: some View {
        List {
            if places.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No places yet", systemImage: "mappin.slash")
                    } description: {
                        Text("Save Home, Work, or any spot — friends you share with get notified when you arrive or leave.")
                    } actions: {
                        Button("Add a place") { editing = .new }
                    }
                }
            } else {
                Section {
                    ForEach(places) { p in
                        Button { editing = .existing(p) } label: { placeRow(p) }
                            .buttonStyle(.plain)
                    }
                    .onDelete(perform: delete)
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = .new } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing) { mode in
            PlaceEditor(sync: sync, mode: mode)
        }
    }

    private func placeRow(_ p: PlaceEntity) -> some View {
        HStack(spacing: 12) {
            Text(p.emoji ?? defaultEmoji(p.type)).font(.title2)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).font(.body)
                Text("\(p.type.capitalized) · \(p.radiusM) m").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func defaultEmoji(_ type: String) -> String {
        switch type { case "home": "🏠"; case "work": "💼"; default: "📍" }
    }

    private func delete(_ offsets: IndexSet) {
        let ids = offsets.map { places[$0].id }
        Task {
            for id in ids {
                do { try await sync.deletePlace(id: id) } catch { self.error = describe(error) }
            }
        }
    }

    private func describe(_ e: Error) -> String {
        if let te = e as? TraxError { return te.message }
        return String(describing: e)
    }
}

/// Add-new vs edit-existing, the sheet's mode.
enum PlaceEdit: Identifiable {
    case new
    case existing(PlaceEntity)
    var id: String {
        switch self { case .new: "new"; case .existing(let p): p.id.uuidString }
    }
}

/// Create/edit a place. Uses the device's current location as the default center
/// (a drop-pin map picker is a later refinement).
struct PlaceEditor: View {
    let sync: TraxSync
    let mode: PlaceEdit
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type = "custom"
    @State private var emoji = ""
    @State private var radius: Double = 150
    @State private var coord: CLLocationCoordinate2D?
    @State private var busy = false
    @State private var error: String?

    private let manager = CLLocationManager()
    private var isEdit: Bool { if case .existing = mode { return true }; return false }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Home)", text: $name)
                    Picker("Type", selection: $type) {
                        Text("Home").tag("home"); Text("Work").tag("work"); Text("Custom").tag("custom")
                    }
                    TextField("Emoji (optional)", text: $emoji)
                }
                Section("Geofence radius") {
                    VStack(alignment: .leading) {
                        Text("\(Int(radius)) m").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $radius, in: 50...1000, step: 25)
                    }
                }
                Section {
                    if let c = coord {
                        Label(String(format: "%.5f, %.5f", c.latitude, c.longitude), systemImage: "location.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Using current location…", systemImage: "location")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle(isEdit ? "Edit place" : "New place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Save", action: save).disabled(!canSave) }
                }
            }
            .onAppear(perform: prime)
        }
    }

    private var canSave: Bool { !name.isEmpty && coord != nil }

    private func prime() {
        if case .existing(let p) = mode {
            name = p.name; type = p.type; emoji = p.emoji ?? ""; radius = Double(p.radiusM)
            coord = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng)
        } else {
            manager.requestWhenInUseAuthorization()
            coord = manager.location?.coordinate
        }
    }

    private func save() {
        guard let c = coord else { return }
        busy = true; error = nil
        let body = PlaceBody(name: name, type: type, lat: c.latitude, lng: c.longitude,
                             radiusM: Int(radius), emoji: emoji.isEmpty ? nil : emoji)
        Task {
            defer { busy = false }
            do {
                if case .existing(let p) = mode {
                    _ = try await sync.updatePlace(id: p.id, body)
                } else {
                    _ = try await sync.createPlace(body)
                }
                dismiss()
            } catch {
                self.error = (error as? TraxError)?.message ?? String(describing: error)
            }
        }
    }
}
