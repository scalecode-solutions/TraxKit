import Foundation

/// Which backend TraxLab talks to. Auth goes to mvServer (WebSocket via MvAuth);
/// location goes to mvTrax (HTTP via TraxKit). Same credentials, two services.
/// During development we select **Local** at the login screen — production is
/// present but never picked.
enum LabServer: String, CaseIterable, Identifiable, Sendable {
    case production = "Production"
    case local = "Local"

    var id: String { rawValue }

    /// mvServer WebSocket endpoint MvAuth logs in against.
    var authWS: URL {
        switch self {
        case .production: URL(string: "wss://api.mvchat.app/v0/ws")!
        case .local:      URL(string: "ws://localhost:6070/v0/ws")!
        }
    }

    /// mvTrax base URL TraxKit talks to.
    var traxBaseURL: URL {
        switch self {
        case .production: URL(string: "https://trax.mvchat.app")!
        case .local:      URL(string: "http://localhost:6091")!
        }
    }
}
