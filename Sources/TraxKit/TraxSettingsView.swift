import SwiftUI
import UIKit

/// My own location settings, pushed by the host (e.g. from its settings): who
/// I am, location access, my places, stopping all sharing, and clearing my
/// history. One person's settings (my share to them, which places they see)
/// live with the conversation: `TraxPairSettingsView`. The host appends its
/// own sections through `extra`.
public struct TraxSettingsView<Extra: View>: View {
    let engine: TraxEngine
    let appearance: TraxAppearance
    let extra: Extra

    @State private var editing: PlaceEdit?
    @State private var confirmStopAll = false
    @State private var confirmClear = false
    @State private var busy = false
    @State private var message: String?
    @Environment(\.traxDisplayNames) private var names

    public init(engine: TraxEngine, appearance: TraxAppearance = .standard, @ViewBuilder extra: () -> Extra) {
        self.engine = engine
        self.appearance = appearance
        self.extra = extra()
    }

    private var me: TraxContact? { engine.people[engine.currentUserID] }
    private var myName: String { names.name(for: engine.currentUserID, people: engine.people, fallback: "You") }
    private var myPlaces: [TraxPlace] { engine.places.filter(\.isMine) }
    private var sharedWithMe: [TraxPlace] { engine.places.filter { !$0.isMine } }

    private func name(for id: UUID) -> String { names.name(for: id, people: engine.people) }

    private func placeTitle(_ place: TraxPlace) -> String {
        "\(place.emoji.map { "\($0) " } ?? "")\(place.name)"
    }

    private func subtitle(_ place: TraxPlace) -> String { traxPlaceSubtitle(place, name: name(for:)) }

    private func placeRow(_ place: TraxPlace) -> some View {
        Button { edit(place) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(placeTitle(place)).foregroundStyle(.primary)
                Text(subtitle(place)).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(place.isMine ? "settings.place.\(place.name)" : "settings.sharedPlace")
    }

    public var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    TraxAvatar(id: engine.currentUserID, name: myName, avatarBase64: me?.avatar, size: 52)
                    Text(myName).font(.headline)
                }
                .padding(.vertical, 4)
            }

            Section {
                access
            } header: {
                Text("Location access")
            } footer: {
                Text(appearance.accessFooter)
            }

            Section {
                ForEach(myPlaces) { placeRow($0) }
                Button { editing = .new } label: { Label("Add a place", systemImage: "plus") }
                    .accessibilityIdentifier("settings.addPlace")
            } header: {
                Text("My places")
            } footer: {
                Text("Choose which of your places each person sees from your conversation with them.")
            }

            if !sharedWithMe.isEmpty {
                Section {
                    ForEach(sharedWithMe) { placeRow($0) }
                } header: {
                    Text("Shared with me")
                } footer: {
                    Text("Places friends share with you. You can both adjust one; its name and type are theirs.")
                }
            }

            Section {
                Button(appearance.stopAllSharing, role: .destructive) { confirmStopAll = true }
                    .disabled(!engine.isSharing || busy)
                    .accessibilityIdentifier("settings.stopAll")
                Button(appearance.clearHistory, role: .destructive) { confirmClear = true }
                    .disabled(busy)
                    .accessibilityIdentifier("settings.clearHistory")
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.message")
                }
            } header: {
                Text("Privacy")
            }

            extra
        }
        .traxBackdrop()
        .navigationTitle("Location")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { mode in PlaceEditor(engine: engine, mode: mode, scope: .selfScoped) }
        .confirmationDialog("Stop sharing your location with everyone?", isPresented: $confirmStopAll,
                            titleVisibility: .visible) {
            Button("Stop sharing", role: .destructive) { run("Stopped sharing.") { try await engine.stopAllSharing() } }
        }
        .confirmationDialog("Clear your location history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) {
                run("History cleared.") { _ = try await engine.clearHistory() }
            }
        } message: {
            Text("Your trail, visits, trips and arrivals are deleted from the server and this device.")
        }
    }

    @ViewBuilder private var access: some View {
        switch engine.authorization {
        case .always:
            LabeledContent("Access", value: "Always")
        case .whenInUse:
            LabeledContent("Access", value: "While using the app")
            Button("Allow in the background") { engine.requestLocationAccess() }
                .accessibilityIdentifier("settings.allowAlways")
        case .notDetermined:
            attention("Not allowed yet")
            Button("Allow location access") { engine.requestLocationAccess() }
                .accessibilityIdentifier("settings.allowLocation")
        case .denied:
            attention("Off")
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
            }
        }
    }

    /// Access that needs the person's attention: always orange (a warning,
    /// not the host's accent), with a symbol so it isn't colour alone.
    private func attention(_ value: String) -> some View {
        LabeledContent {
            Label(value, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } label: {
            Text("Access")
        }
        .accessibilityIdentifier("settings.accessAttention")
    }

    private func edit(_ place: TraxPlace) {
        guard let snapshot = engine.sync.placeSnapshots.first(where: { $0.id == place.id }) else { return }
        editing = .existing(snapshot)
    }

    private func run(_ done: String, _ action: @escaping () async throws -> Void) {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do { try await action(); message = done }
            catch { message = "That didn't work. Try again." }
        }
    }
}

/// A place row's second line in my settings: who shared it with me, or who I
/// share it with, or just its kind.
func traxPlaceSubtitle(_ place: TraxPlace, name: (UUID) -> String) -> String {
    if !place.isMine { return "Shared by \(name(place.ownerID))" }
    if place.isShared { return "Shared with " + place.sharedWith.map(name).joined(separator: ", ") }
    return place.kind.rawValue.capitalized
}

public extension TraxSettingsView where Extra == EmptyView {
    init(engine: TraxEngine, appearance: TraxAppearance = .standard) {
        self.init(engine: engine, appearance: appearance) { EmptyView() }
    }
}
