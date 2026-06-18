import SwiftUI
import SwiftData

/// Settings (the gear): own identity + account actions. Sharing/privacy control
/// ("who can see me") now lives on the Me surface (tap your own row), so this is
/// just settings + sign out — not the primary self surface.
public struct TraxSettingsView: View {
    let sync: TraxSync
    let onSignOut: (() -> Void)?

    @State private var me: TraxContact?

    public init(sync: TraxSync, onSignOut: (() -> Void)? = nil) {
        self.sync = sync
        self.onSignOut = onSignOut
    }

    public var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    TraxAvatar(id: me?.id, name: me?.name, avatarBase64: me?.avatar, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(me?.name ?? "You").font(.headline)
                        Text("Signed in").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section {
                Label("Manage who can see you from the Me tab — tap your own row on the map.",
                      systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if let onSignOut {
                Section {
                    Button("Sign Out", role: .destructive) { onSignOut() }
                }
            }
        }
        .task { me = try? await sync.me() }
    }
}
