import SwiftUI
import SwiftData
import CoreLocation

// Places pill pane: "Add a Place" + the user's saved places. Tap a row to edit;
// the hub renders the place pins on the map when this pill is active. The editor
// sheet lives here too (moved from the old standalone Places tab).

struct TraxHubPlacesContent: View {
    let places: [PlaceEntity]
    let onAdd: () -> Void
    let onEdit: (PlaceEntity) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onAdd) {
                HStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(Color.accentColor, in: .circle)
                    Text("Add a Place").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.accentColor)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !places.isEmpty { Divider().padding(.leading, 74) }

            ForEach(places) { p in
                Button { onEdit(p) } label: {
                    HStack(spacing: 14) {
                        Text(p.emoji ?? defaultEmoji(p.type)).font(.title2)
                            .frame(width: 44, height: 44).background(Color.accentColor.opacity(0.12), in: .circle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.system(size: 17, weight: .semibold))
                            Text("\(p.type.capitalized) · \(p.radiusM) m").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.forward").font(.footnote).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if p.id != places.last?.id { Divider().padding(.leading, 74) }
            }
        }
    }

    private func defaultEmoji(_ type: String) -> String {
        switch type { case "home": "🏠"; case "work": "💼"; default: "📍" }
    }
}

/// Add-new vs edit-existing, the editor sheet's mode.
enum PlaceEdit: Identifiable {
    case new
    case existing(PlaceEntity)
    var id: String { switch self { case .new: "new"; case .existing(let p): p.id.uuidString } }
}

/// Create/edit a place. Uses the device's current location as the default center.
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
