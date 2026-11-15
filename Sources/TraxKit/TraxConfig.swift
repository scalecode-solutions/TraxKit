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
    /// "group.com.example.app"); nil → the app's own container (TraxLab/dev).
    public let appGroup: String?
    /// Where the local store lives, when the host wants it somewhere specific
    /// (e.g. a folder it keeps out of device backups). The kit creates the folder
    /// if needed and keeps `Trax-<user id>.store` (and SQLite's `-wal`/`-shm`) in
    /// it. Takes precedence over `appGroup`; nil → `appGroup`'s rules.
    public let storeDirectory: URL?

    public init(baseURL: URL,
                currentUserID: UUID,
                tokenProvider: @escaping @Sendable () async -> String?,
                weatherProvider: (any TraxWeatherProviding)? = nil,
                appGroup: String? = nil,
                storeDirectory: URL? = nil) {
        self.baseURL = baseURL
        self.currentUserID = currentUserID
        self.tokenProvider = tokenProvider
        self.weatherProvider = weatherProvider
        self.appGroup = appGroup
        self.storeDirectory = storeDirectory
    }

    /// The live transport — Connect/protobuf against mvTrax (REST retired).
    public var transport: any TraxTransport {
        ConnectTraxTransport(baseURL: baseURL, tokenProvider: tokenProvider)
    }
}
