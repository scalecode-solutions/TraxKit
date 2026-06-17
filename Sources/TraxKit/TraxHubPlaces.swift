import SwiftUI
import SwiftData
import CoreLocation

// Places pill pane: "Add a Place" + the user's saved places. Tap a row to edit;
// the hub renders the place pins on the map when this pill is active. The editor
// sheet lives here too (moved from the old standalone Places tab).

struct TraxHubPlacesContent: View {
    let places: [PlaceEntity]
    let currentUserID: UUID
    let nameFor: (UUID) -> String
    let onAdd: () -> Void
    let onEdit: (PlaceEntity) -> Void

    private func subtitle(_ p: PlaceEntity) -> String {
        if p.ownerId != currentUserID { return "Shared by \(nameFor(p.ownerId))" }
        if p.isShared { return "Shared with " + p.sharedWith.map(nameFor).joined(separator: ", ") }
        return "\(p.type.capitalized) · \(p.radiusM) m"
    }
    private func isOurSpot(_ p: PlaceEntity) -> Bool { p.ownerId != currentUserID || p.isShared }

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
                            HStack(spacing: 5) {
                                Text(p.name).font(.system(size: 17, weight: .semibold))
                                if isOurSpot(p) {
                                    Image(systemName: "person.2.fill").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                                }
                            }
                            Text(subtitle(p)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
/// For an existing custom place, a "Shared with" section co-owns it with friends.
struct PlaceEditor: View {
    let sync: TraxSync
    let mode: PlaceEdit
    let currentUserID: UUID
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ContactEntity.name) private var contacts: [ContactEntity]

    @State private var name = ""
    @State private var type = "custom"
    @State private var emoji = ""
    @State private var radius: Double = 150
    @State private var coord: CLLocationCoordinate2D?
    @State private var busy = false
    @State private var error: String?
    // Captured on prime so we never touch the @Model after loadPlaces reinserts it.
    @State private var placeID: UUID?
    @State private var ownerID: UUID?
    @State private var members: [UUID] = []
    @State private var addingMember = false

    private let manager = CLLocationManager()
    private var isEdit: Bool { if case .existing = mode { return true }; return false }
    private var isOwner: Bool { ownerID == currentUserID }
    private var canShare: Bool { isEdit && type == "custom" && placeID != nil }

    private func name(for id: UUID) -> String {
        let n = contacts.first { $0.id == id }?.name
        return (n?.isEmpty == false ? n! : "Member \(id.uuidString.prefix(8))")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Home)", text: $name).disabled(!isOwner && isEdit)
                    if isOwner || !isEdit {
                        Picker("Type", selection: $type) {
                            Text("Home").tag("home"); Text("Work").tag("work"); Text("Custom").tag("custom")
                        }
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
                if canShare { sharedSection }
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

    // Co-owned "our spot" sharing — custom places only.
    @ViewBuilder private var sharedSection: some View {
        Section {
            ForEach(members, id: \.self) { id in
                HStack {
                    Label(name(for: id), systemImage: "person.fill")
                    Spacer()
                    Button("Remove", role: .destructive) { unshare(id) }.buttonStyle(.borderless).font(.caption)
                }
            }
            let candidates = contacts.filter { $0.id != currentUserID && !members.contains($0.id) }
            if addingMember {
                if candidates.isEmpty {
                    Text("No more friends to add").foregroundStyle(.secondary).font(.caption)
                } else {
                    ForEach(candidates) { c in
                        Button { share(c.id) } label: {
                            Label(name(for: c.id), systemImage: "plus.circle.fill")
                        }
                    }
                }
            } else {
                Button { addingMember = true } label: { Label("Share with a friend", systemImage: "person.badge.plus") }
            }
        } header: {
            Text("Shared with")
        } footer: {
            Text("Both of you see this place and get notified when either arrives or leaves.")
        }
    }

    private var canSave: Bool { !name.isEmpty && coord != nil }

    private func prime() {
        if case .existing(let p) = mode {
            name = p.name; type = p.type; emoji = p.emoji ?? ""; radius = Double(p.radiusM)
            coord = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng)
            placeID = p.id; ownerID = p.ownerId; members = p.sharedWith
        } else {
            manager.requestWhenInUseAuthorization()
            coord = manager.location?.coordinate
            ownerID = currentUserID
        }
    }

    private func share(_ viewer: UUID) {
        guard let id = placeID else { return }
        members.append(viewer); addingMember = false
        Task { do { try await sync.sharePlace(id: id, viewer: viewer) }
               catch { self.error = describe(error); members.removeAll { $0 == viewer } } }
    }

    private func unshare(_ viewer: UUID) {
        guard let id = placeID else { return }
        members.removeAll { $0 == viewer }
        Task { do { try await sync.unsharePlace(id: id, viewer: viewer) }
               catch { self.error = describe(error); members.append(viewer) } }
    }

    private func save() {
        guard let c = coord else { return }
        busy = true; error = nil
        let body = PlaceBody(name: name, type: type, lat: c.latitude, lng: c.longitude,
                             radiusM: Int(radius), emoji: emoji.isEmpty ? nil : emoji)
        Task {
            defer { busy = false }
            do {
                if let id = placeID {
                    _ = try await sync.updatePlace(id: id, body)
                } else {
                    _ = try await sync.createPlace(body)
                }
                dismiss()
            } catch {
                self.error = describe(error)
            }
        }
    }

    private func describe(_ e: Error) -> String {
        if let te = e as? TraxError { return te.message }
        return String(describing: e)
    }
}
