import Foundation

/// Everything TraxKit needs from the host. A `Sendable` value. The token provider
/// is `@Sendable` + `async` so the host can supply the current mvServer access
/// token (auto-refreshed) from its own actor; it's invoked off the caller's actor.
public struct TraxConfig: Sendable {
    public let baseURL: URL
    /// The signed-in user, so the UI can tell "mine" from "theirs".
    public let currentUserID: UUID
    public let tokenProvider: @Sendable () async -> String?
    /// Optional weather source; nil → TraxKit's WeatherKit default.
    public let weatherProvider: (any TraxWeatherProviding)?
    /// The host's App-Group identifier for the local store (e.g.
    /// "group.app.mvchat.Clingy3"); nil → the app's own container (TraxLab/dev).
    public let appGroup: String?

    public init(baseURL: URL,
                currentUserID: UUID,
                tokenProvider: @escaping @Sendable () async -> String?,
                weatherProvider: (any TraxWeatherProviding)? = nil,
                appGroup: String? = nil) {
        self.baseURL = baseURL
        self.currentUserID = currentUserID
        self.tokenProvider = tokenProvider
        self.weatherProvider = weatherProvider
        self.appGroup = appGroup
    }

    /// The live transport for this config.
    public var transport: any TraxTransport {
        HTTPTraxTransport(baseURL: baseURL, tokenProvider: tokenProvider)
    }
}
