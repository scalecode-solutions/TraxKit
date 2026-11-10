import Foundation
import Observation
import UIKit
import MvAuth

/// Real mvServer auth for TraxLab. Logs in via MvAuth (WebSocket), holds the
/// token set, and hands TraxKit a token provider that auto-refreshes. Replaces
/// the old dev-minted JWT — the access token here is a genuine mvServer JWT,
/// exactly what mvPulse validates.
@MainActor
@Observable
final class AuthModel {
    enum State: Equatable {
        case loggedOut
        case loggingIn
        case loggedIn(UserProfile)
        case failed(String)
    }

    private(set) var state: State = .loggedOut
    private(set) var profile: UserProfile?
    private(set) var server: LabServer = .production

    private var tokens: TokenSet?
    private var client: MvAuthClient?

    var isLoggingIn: Bool { state == .loggingIn }

    func login(server: LabServer, username: String, password: String) async {
        self.server = server
        state = .loggingIn

        let info = ClientInfo(
            protocolVersion: "0.1.0",
            userAgent: "TraxLab/1.0 iOS",
            appBuild: "1",
            language: "en",
            platform: "ios",
            timeZone: TimeZone.current.identifier,
            deviceID: UIDevice.current.identifierForVendor?.uuidString
        )
        let client = MvAuthClient(serverURL: server.authWS, clientInfo: info)
        self.client = client

        do {
            let result = try await client.login(username: username, password: password)
            tokens = result.tokens
            profile = result.profile
            state = .loggedIn(result.profile)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    func logOut() {
        tokens = nil
        profile = nil
        client = nil
        state = .loggedOut
    }

    /// The current access token for TraxKit, refreshed when near expiry. Returns
    /// nil (and logs out) if the refresh token is dead — TraxKit then 401s and
    /// the UI falls back to the login screen.
    func accessToken() async -> String? {
        guard let tokens, let client else { return nil }
        guard tokens.shouldRefreshAccessToken else { return tokens.accessToken }
        do {
            let fresh = try await client.refresh(refreshToken: tokens.refreshToken)
            self.tokens = fresh
            return fresh.accessToken
        } catch {
            logOut()
            return nil
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let e = error as? MvAuthError else { return error.localizedDescription }
        switch e {
        case .serverError(let code, let text):
            return text ?? "Login failed (\(code))"
        case .connectionFailed, .connectionClosed, .timeout:
            return "Can't reach the server. Check the network and try again."
        case .refreshTokenExpired:
            return "Session expired. Please log in again."
        case .handshakeFailed(let reason):
            return "Handshake failed: \(reason)"
        case .malformedResponse, .underlying:
            return "Unexpected server response."
        }
    }
}
