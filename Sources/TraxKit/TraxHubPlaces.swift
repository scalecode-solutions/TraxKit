import SwiftUI
import SwiftData
import CoreLocation
import MapKit

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

/// Backs the address autocomplete in PlaceEditor: wraps `MKLocalSearchCompleter`
/// (live suggestions as you type) and resolves a tapped suggestion to a coordinate
/// via `MKLocalSearch`. Region-biased to the map's current view for local relevance.
@MainActor
@Observable
final class AddressSearchModel: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { results = [] } else { completer.queryFragment = q }
        }
    }
    private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Bias suggestions toward the map's current view so "Main St" finds the nearby one.
    func bias(to region: MKCoordinateRegion) { completer.region = region }

    nonisolated func completerDidUpdateResults(_ c: MKLocalSearchCompleter) {
        // MKLocalSearchCompleter delivers on the main thread, so we're already
        // MainActor-isolated — assume it, and read from the stored completer
        // (capturing self, the isolated instance) rather than sending the
        // non-Sendable parameter across an actor boundary (Swift 6 forbids both).
        MainActor.assumeIsolated { self.results = self.completer.results }
    }
    nonisolated func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.results = [] }
    }

    /// Resolve a tapped suggestion to a coordinate.
    func resolve(_ completion: MKLocalSearchCompletion) async -> CLLocationCoordinate2D? {
        let resp = try? await MKLocalSearch(request: .init(completion: completion)).start()
        return resp?.mapItems.first?.placemark.coordinate
    }
}

/// Create/edit a place with a real map picker: type an address (live autocomplete),
/// drag the map under the center pin, or tap locate-me. For an existing custom
/// place, a "Shared with" section co-owns it with friends.
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

    // Map picker + address search.
    @State private var camera: MapCameraPosition = .automatic
    @State private var search = AddressSearchModel()
    @State private var address: String?            // reverse-geocoded label for the pinned spot
    @FocusState private var queryFocused: Bool

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var isEdit: Bool { if case .existing = mode { return true }; return false }
    private var isOwner: Bool { ownerID == currentUserID }
    private var canShare: Bool { isEdit && type == "custom" && placeID != nil }

    private func name(for id: UUID) -> String {
        let n = contacts.first { $0.id == id }?.name
        return (n?.isEmpty == false ? n! : "Member \(id.uuidString.prefix(8))")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapPicker.frame(height: 300)
                Form {
                    Section { addressRow }
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
                    if canShare { sharedSection }
                    if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
                }
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

    // MARK: - Map picker

    /// The map fills the top; a fixed center pin marks the spot, so panning the map
    /// under it sets the location (no tap-to-drop gesture fight). Search + locate-me
    /// float on top.
    private var mapPicker: some View {
        Map(position: $camera) { UserAnnotation() }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                coord = ctx.region.center
                search.bias(to: ctx.region)
                Task { await reverseGeocode(ctx.region.center) }
            }
            .overlay {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)
                    .background(Circle().fill(.white).padding(6))
                    .shadow(radius: 3)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) { searchOverlay }
            .overlay(alignment: .bottomTrailing) { locateButton }
    }

    private var searchOverlay: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search address or place", text: $search.query)
                    .focused($queryFocused)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !search.query.isEmpty {
                    Button { search.query = ""; queryFocused = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))

            if queryFocused && !search.results.isEmpty {
                let top = Array(search.results.prefix(5))
                VStack(spacing: 0) {
                    ForEach(top, id: \.self) { r in
                        Button { pick(r) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.title).font(.subheadline).foregroundStyle(.primary)
                                if !r.subtitle.isEmpty {
                                    Text(r.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        if r != top.last { Divider() }
                    }
                }
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
        .padding(12)
    }

    private var locateButton: some View {
        Button {
            manager.requestWhenInUseAuthorization()
            if let loc = manager.location?.coordinate { flyTo(loc) }
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 15, weight: .semibold))
                .padding(11)
                .background(.regularMaterial, in: .circle)
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .padding(12)
    }

    private var addressRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(address ?? "Drag the map to set the spot")
                    .font(.subheadline)
                    .foregroundStyle(address == nil ? .secondary : .primary)
                if let c = coord {
                    Text(String(format: "%.5f, %.5f", c.latitude, c.longitude))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func pick(_ completion: MKLocalSearchCompletion) {
        queryFocused = false
        search.query = completion.title
        Task {
            if let c = await search.resolve(completion) { flyTo(c) }
        }
    }

    private func flyTo(_ c: CLLocationCoordinate2D) {
        coord = c
        withAnimation {
            camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 600, longitudinalMeters: 600))
        }
        Task { await reverseGeocode(c) }
    }

    private func reverseGeocode(_ c: CLLocationCoordinate2D) async {
        let marks = try? await geocoder.reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude))
        guard let p = marks?.first else { return }
        let line1 = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let line2 = [p.locality, p.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        let full = [line1, line2].filter { !$0.isEmpty }.joined(separator: ", ")
        address = full.isEmpty ? nil : full
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
            let c = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng)
            coord = c
            camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 600, longitudinalMeters: 600))
            placeID = p.id; ownerID = p.ownerId; members = p.sharedWith
            Task { await reverseGeocode(c) }
        } else {
            manager.requestWhenInUseAuthorization()
            ownerID = currentUserID
            if let loc = manager.location?.coordinate {
                coord = loc
                camera = .region(MKCoordinateRegion(center: loc, latitudinalMeters: 600, longitudinalMeters: 600))
                Task { await reverseGeocode(loc) }
            } else {
                camera = .userLocation(fallback: .automatic)   // follow until the first fix lands
            }
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
