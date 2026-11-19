import SwiftUI

/// One person's location settings, pushed by the host from the conversation
/// with them: my share to them (start, change precision or duration, stop) and
/// which of my custom places they see. These are the two people's things;
/// `TraxSettingsView` holds only my own.
public struct TraxPairSettingsView: View {
    let engine: TraxEngine
    let otherID: UUID
    let appearance: TraxAppearance

    /// Optimistic toggle state while a share/unshare round-trip flies.
    @State private var pending: [UUID: Bool] = [:]
    @State private var error: String?

    public init(engine: TraxEngine, otherID: UUID, appearance: TraxAppearance = .standard) {
        self.engine = engine
        self.otherID = otherID
        self.appearance = appearance
    }

    private var name: String {
        let n = engine.people[otherID]?.name
        return (n?.isEmpty == false ? n! : "Member \(otherID.uuidString.prefix(8))")
    }

    /// Custom places only: home and work always stay private.
    private var myPlaces: [TraxPlace] { engine.places.filter { $0.isMine && $0.kind == .custom } }

    public var body: some View {
        List {
            Section {
                TraxShareControls(engine: engine, personID: otherID, personName: name, appearance: appearance)
                    .padding(.vertical, 4)
            } header: {
                Text("My location")
            }
            Section {
                ForEach(myPlaces) { place in
                    Toggle(isOn: binding(for: place)) {
                        Text("\(place.emoji.map { "\($0) " } ?? "")\(place.name)")
                    }
                    .accessibilityIdentifier("pair.place.\(place.name)")
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Places \(name) can see")
            } footer: {
                Text(myPlaces.isEmpty
                     ? "You have no custom places yet. Add one in location settings, then choose here which ones \(name) sees."
                     : "Shared places show on both your maps, and \(name) gets your arrivals and departures there. Home and work always stay private.")
            }
        }
        .navigationTitle("Location")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(for place: TraxPlace) -> Binding<Bool> {
        Binding(
            get: { pending[place.id] ?? place.sharedWith.contains(otherID) },
            set: { on in
                pending[place.id] = on
                error = nil
                Task {
                    do {
                        if on { try await engine.sharePlace(place.id, with: otherID) }
                        else { try await engine.unsharePlace(place.id, with: otherID) }
                    } catch {
                        self.error = "Couldn't update sharing. Try again."
                    }
                    pending[place.id] = nil   // the published places are the truth again
                }
            })
    }
}
