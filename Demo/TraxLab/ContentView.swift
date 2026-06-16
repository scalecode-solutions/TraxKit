import SwiftUI
import TraxKit
import MvAuth

struct ContentView: View {
    @State private var auth = AuthModel()

    var body: some View {
        switch auth.state {
        case .loggedIn(let profile):
            tracker(for: profile)
        default:
            LoginView(auth: auth)
        }
    }

    private func tracker(for profile: UserProfile) -> some View {
        let tokenProvider: @Sendable () async -> String? = { [auth] in await auth.accessToken() }
        let config = TraxConfig(
            baseURL: auth.server.traxBaseURL,
            currentUserID: UUID(uuidString: profile.userID) ?? UUID(),
            tokenProvider: tokenProvider
        )
        return NavigationStack {
            TraxLocationView(config: config, store: TraxStore(inMemory: true))
                .navigationTitle("Trax")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Sign Out", role: .destructive) { auth.logOut() }
                    }
                }
        }
    }
}

#Preview {
    ContentView()
        .tint(.tardisBlue)
}
