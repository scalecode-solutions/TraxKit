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

    public init(engine: TraxEngine, appearance: TraxAppearance = .standard, @ViewBuilder extra: () -> Extra) {
        self.engine = engine
        self.appearance = appearance
        self.extra = extra()
    }

    private var me: TraxContact? { engine.people[engine.currentUserID] }
    private var myPlaces: [TraxPlace] { engine.places.filter(\.isMine) }

    public var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    TraxAvatar(id: engine.currentUserID, name: me?.name, avatarBase64: me?.avatar, size: 52)
                    Text(me?.name ?? "You").font(.headline)
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
                ForEach(myPlaces) { place in
                    Button { edit(place) } label: {
                        LabeledContent {
                            Text(place.kind.rawValue.capitalized).foregroundStyle(.secondary)
                        } label: {
                            Text("\(place.emoji.map { "\($0) " } ?? "")\(place.name)")
                                .foregroundStyle(.primary)
                        }
                    }
                    .accessibilityIdentifier("settings.place.\(place.name)")
                }
                Button { editing = .new } label: { Label("Add a place", systemImage: "plus") }
                    .accessibilityIdentifier("settings.addPlace")
            } header: {
                Text("My places")
            } footer: {
                Text("Choose which of your places each person sees from your conversation with them.")
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
        .sheet(item: $editing) { mode in PlaceEditor(engine: engine, mode: mode) }
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
            Button("Allow location access") { engine.requestLocationAccess() }
                .accessibilityIdentifier("settings.allowLocation")
        case .denied:
            LabeledContent("Access", value: "Off")
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
            }
        }
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

public extension TraxSettingsView where Extra == EmptyView {
    init(engine: TraxEngine, appearance: TraxAppearance = .standard) {
        self.init(engine: engine, appearance: appearance) { EmptyView() }
    }
}
