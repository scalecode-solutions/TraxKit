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
                LabeledContent("Friend", value: friend.uuidString.prefix(8) + "…")
                    .font(.caption.monospaced())
            }
        }
        .navigationTitle("Conversation")
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
