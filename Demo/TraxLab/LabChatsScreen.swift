import SwiftUI
import CoreLocation
import TraxKit

/// The Chats tab: one conversation with `LAB_FRIEND`, whose header reads the
/// kit's bridge (`TraxLocationStore.relationship(with:)`) straight from the
/// view body, the way a chat host's thread header does. TraxKit's hub reads
/// differently, so this screen is the Lab's check that bridge readers update
/// live: leave it open while the friend moves, and the coordinate, place and
/// "updated" line must change without leaving the screen.
struct LabChatsScreen: View {
    let session: LabSession
    let friend: UUID?

    var body: some View {
        NavigationStack {
            if let friend {
                LabConversation(session: session, friend: friend)
            } else {
                ContentUnavailableView("No conversation",
                                       systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Launch with LAB_FRIEND=<uuid> to open one."))
                    .navigationTitle("Chats")
            }
        }
    }
}

private struct LabConversation: View {
    let session: LabSession
    let friend: UUID
    @State private var hold = LabMapHold()

    var body: some View {
        let rel = session.engine.relationship(with: friend)
        List {
            Section("They share with me") {
                if let s = rel.incoming {
                    row("Coordinate", Self.format(s.coordinate), id: "friend.coordinate")
                    row("Place", s.placeName ?? "—", id: "friend.place")
                    row("Live", s.isLive ? "yes" : "no", id: "friend.live")
                    row("Battery", s.battery.map { "\($0)%\(s.batteryCharging ? " ⚡" : "")" } ?? "—", id: "friend.battery")
                    row("Updated", Self.format(ms: s.lastUpdatedMs), id: "friend.updated")
                } else {
                    Text("Not sharing").foregroundStyle(.secondary)
                        .accessibilityIdentifier("friend.notSharing")
                }
            }
            Section("I share with them") {
                if let o = rel.outgoing {
                    row("Precision", o.precision, id: "me.precision")
                    row("Mode", o.mode, id: "me.mode")
                } else {
                    Text("Not sharing").foregroundStyle(.secondary)
                        .accessibilityIdentifier("me.notSharing")
                }
            }
            Section {
                // How a chat host reaches the kit's per-person screens.
                NavigationLink {
                    LabPersonMapScreen(session: session, friend: friend)
                } label: { Label("Map", systemImage: "map") }
                    .accessibilityIdentifier("conversation.map")
                NavigationLink {
                    TraxPairSettingsView(engine: session.engine, otherID: friend)
                } label: { Label("Location settings", systemImage: "location.circle") }
                    .accessibilityIdentifier("conversation.pairSettings")
            }
            Section {
                LabeledContent("Friend", value: friend.uuidString.prefix(8) + "…")
                    .font(.caption.monospaced())
            }
        }
        .navigationTitle("Conversation")
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text("Conversation").font(.headline)
                    TraxShareBadge(engine: session.engine, otherID: friend)
                }
            }
        }
        .onAppear { hold.arm(session) }
    }

    private func row(_ label: String, _ value: String, id: String) -> some View {
        LabeledContent(label) {
            Text(value).monospacedDigit().accessibilityIdentifier(id)
        }
    }

    private static func format(_ c: CLLocationCoordinate2D?) -> String {
        guard let c else { return "—" }
        return String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }

    private static func format(ms: Int64?) -> String {
        guard let ms else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return date.formatted(date: .omitted, time: .standard)
    }
}

/// The kit's person map, pushed from the conversation, holding the engine while
/// it's in the stack (fast poll), as a chat host's destination does.
private struct LabPersonMapScreen: View {
    let session: LabSession
    let friend: UUID
    @State private var hold = LabMapHold()

    /// LAB_HIDE_TAB_BAR=1: push the map with the tab bar hidden, as a chat
    /// host may, so the card has nothing under it at the bottom edge.
    private var hidesTabBar: Bool { ProcessInfo.processInfo.environment["LAB_HIDE_TAB_BAR"] == "1" }

    var body: some View {
        TraxView(engine: session.engine, focus: .constant(.person(friend)))
            .toolbar(hidesTabBar ? .hidden : .automatic, for: .tabBar)
            .onAppear { hold.arm(session) }
    }
}
