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

/// The dev host: builds a `TraxEngine` with the lab's device location-host
/// (`TraxLabLocationEngine` — the seam impl), and drives `start()`/`stop()` the way
/// real Clingy's session machinery will. TraxKit owns the rest (map, places,
/// settings); the lab injects sign-out, which the kit surfaces in the Me view.
struct TraxLabHost: View {
    let auth: AuthModel
    @State private var engine: TraxEngine

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
        TraxRootView(engine: engine) { auth.logOut() }
            .task { engine.start() }
            .onDisappear { engine.stop() }
    }
}

#Preview {
    ContentView()
        .tint(.tardisBlue)
}
