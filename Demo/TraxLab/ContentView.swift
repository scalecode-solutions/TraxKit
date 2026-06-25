import SwiftUI
import TraxKit
import MvAuth

struct ContentView: View {
    @State private var auth = AuthModel()

    var body: some View {
        switch auth.state {
        case .loggedIn(let profile):
            TraxLabHost(profile: profile, auth: auth)
                .id(profile.userID)   // a fresh engine (+ per-user store) per identity
        default:
            LoginView(auth: auth)
        }
    }
}

private enum LabTab: Hashable { case chats, trax, pulse, me }

/// The dev host: builds a `TraxEngine` with the lab's device location-host
/// (`TraxLabLocationEngine` — the seam impl), drives `start()`/`stop()`, and wraps
/// the embedded hub in a **Clingy-shaped tab bar** so the sheet-behind-the-tab-bar
/// case is real here (3 stub tabs + the live Trax map). The engine runs app-wide,
/// across tab switches — exactly how Clingy hoists it.
struct TraxLabHost: View {
    let auth: AuthModel
    @State private var engine: TraxEngine
    @State private var tab: LabTab = .trax

    init(profile: UserProfile, auth: AuthModel) {
        self.auth = auth
        let config = TraxConfig(
            baseURL: auth.server.traxBaseURL,
            currentUserID: UUID(uuidString: profile.userID) ?? UUID(),
            tokenProvider: { [auth] in await auth.accessToken() }
        )
        _engine = State(initialValue: TraxEngine(config: config, host: TraxLabLocationEngine()))
    }

    var body: some View {
        TabView(selection: $tab) {
            StubScreen(title: "Chats", systemImage: "bubble.left.and.text.bubble.right.fill")
                .tabItem { Label("Chats", systemImage: "bubble.left.and.text.bubble.right.fill") }
                .tag(LabTab.chats)

            // The real thing — embedded (host owns the nav chrome), so TraxKit drops
            // its own NavigationStack and we provide one here for the floating toolbar.
            NavigationStack {
                TraxRootView(engine: engine, embedded: true) { auth.logOut() }
            }
            .tabItem { Label("Trax", systemImage: "mappin.and.ellipse") }
            .tag(LabTab.trax)

            StubScreen(title: "Pulse", systemImage: "waveform.path.ecg")
                .tabItem { Label("Pulse", systemImage: "waveform.path.ecg") }
                .tag(LabTab.pulse)

            StubScreen(title: "Me", systemImage: "person.crop.circle")
                .tabItem { Label("Me", systemImage: "person.crop.circle") }
                .tag(LabTab.me)
        }
        .tint(.tardisBlue)
        .task { engine.start() }
        .onDisappear { engine.stop() }
    }
}

/// Placeholder tab — exists only to give the lab a genuine bottom tab bar that
/// overlaps the hub's sheet, mirroring Clingy's chrome.
private struct StubScreen: View {
    let title: String
    let systemImage: String

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(title).font(.title2.bold())
                    Text("Stub screen — tab-bar reference only")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(title)
        }
    }
}

#Preview {
    ContentView()
        .tint(.tardisBlue)
}
