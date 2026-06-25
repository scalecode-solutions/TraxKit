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
    /// Wire: Connect/protobuf (the new rail) vs the legacy REST/JSON transport.
    /// Both speak to the same mvTrax; flip to false to fall back during the cutover.
    public let useConnect: Bool

    public init(baseURL: URL,
                currentUserID: UUID,
                tokenProvider: @escaping @Sendable () async -> String?,
                weatherProvider: (any TraxWeatherProviding)? = nil,
                appGroup: String? = nil,
                useConnect: Bool = true) {
        self.baseURL = baseURL
        self.currentUserID = currentUserID
        self.tokenProvider = tokenProvider
        self.weatherProvider = weatherProvider
        self.appGroup = appGroup
        self.useConnect = useConnect
    }

    /// The live transport for this config.
    public var transport: any TraxTransport {
        useConnect
            ? ConnectTraxTransport(baseURL: baseURL, tokenProvider: tokenProvider)
            : HTTPTraxTransport(baseURL: baseURL, tokenProvider: tokenProvider)
    }
}
