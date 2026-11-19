import SwiftUI
import TraxKit
import MvAuth

struct ContentView: View {
    @State private var auth = AuthModel()

    var body: some View {
        #if DEBUG
        if let dev = DevSignIn.fromEnvironment() {
            TraxLabHost(userID: dev.user, server: .local, tokenProvider: { dev.token }, signOut: {})
        } else {
            signedIn
        }
        #else
        signedIn
        #endif
    }

    @ViewBuilder private var signedIn: some View {
        switch auth.state {
        case .loggedIn(let profile):
            TraxLabHost(userID: profile.userID, server: auth.server,
                        tokenProvider: { [auth] in await auth.accessToken() },
                        signOut: { auth.logOut() })
                .id(profile.userID) // a fresh engine (and per-user store) per identity
        default:
            LoginView(auth: auth)
        }
    }
}

#if DEBUG
/// Debug-only: skip the login with a token minted from the LOCAL key (launch
/// environment TRAX_DEV_TOKEN + TRAX_DEV_USER). Only meaningful against the
/// local stack; compiled out of release builds.
struct DevSignIn {
    let token: String
    let user: String

    static func fromEnvironment() -> DevSignIn? {
        let e = ProcessInfo.processInfo.environment
        guard let t = e["TRAX_DEV_TOKEN"], let u = e["TRAX_DEV_USER"], UUID(uuidString: u) != nil else { return nil }
        return DevSignIn(token: t, user: u)
    }
}
#endif

/// Lab-only launch options (debug and release alike; harmless when unset).
enum LabLaunch {
    /// LAB_FRIEND=<uuid>: the person the Chats tab's conversation is with.
    static var friend: UUID? {
        ProcessInfo.processInfo.environment["LAB_FRIEND"].flatMap(UUID.init(uuidString:))
    }
    /// LAB_START=chats opens on the conversation instead of the map.
    static var startTab: LabTab {
        ProcessInfo.processInfo.environment["LAB_START"] == "chats" ? .chats : .trax
    }
}

enum LabTab: Hashable { case chats, trax, pulse, me }

/// The dev host: builds a `TraxEngine` with the kit's own device location
/// engine (`TraxLocationEngine`, default no-op policy) and hosts it the way a
/// chat app does: a tab bar whose sheet overlaps the hub, and a conversation
/// that reads the kit's bridge. `LabSession` runs the engine app-wide from
/// sign-in; sign-out wipes it, as a production host does.
struct TraxLabHost: View {
    let userID: String
    let server: LabServer
    let signOut: () -> Void
    @State private var session: LabSession
    @State private var tab: LabTab = LabLaunch.startTab

    init(userID: String, server: LabServer, tokenProvider: @escaping @Sendable () async -> String?,
         signOut: @escaping () -> Void) {
        self.userID = userID
        self.server = server
        self.signOut = signOut
        let config = TraxConfig(
            baseURL: server.traxBaseURL,
            currentUserID: UUID(uuidString: userID) ?? UUID(),
            tokenProvider: tokenProvider
        )
        _session = State(initialValue: LabSession(engine: TraxEngine(config: config, host: TraxLocationEngine())))
    }

    var body: some View {
        TabView(selection: $tab) {
            LabChatsScreen(session: session, friend: LabLaunch.friend)
                .tabItem { Label("Chats", systemImage: "bubble.left.and.text.bubble.right.fill") }
                .tag(LabTab.chats)

            // The real thing, embedded: the host owns the nav chrome, so TraxKit
            // drops its own NavigationStack and we provide one for the toolbar.
            NavigationStack {
                LabHubScreen(session: session, signOut: endSession)
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
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }

    /// Sign-out wipes this account's local store (production hosts do the same).
    private func endSession() {
        session.wipe()
        signOut()
    }
}

/// The kit's hub, holding the session while it's on screen.
private struct LabHubScreen: View {
    let session: LabSession
    let signOut: () -> Void
    @State private var hold = LabMapHold()

    var body: some View {
        TraxRootView(engine: session.engine, embedded: true, onSignOut: signOut)
            .onAppear { hold.arm(session) }
    }
}

/// Placeholder tab: gives the lab a genuine bottom tab bar that overlaps the
/// hub's sheet, mirroring a host app's chrome.
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
                    Text("Stub screen, tab-bar reference only")
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
