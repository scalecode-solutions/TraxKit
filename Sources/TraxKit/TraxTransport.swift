import Foundation

/// The network boundary. A protocol so the sync engine + UI are testable with a
/// fake (no server), exactly like PulseKit's `PulseTransport` seam.
public protocol TraxTransport: Sendable {
    // Viewer feed (who's sharing with me + where they are now).
    func feed(since: Int64?, limit: Int?) async throws -> FeedDTO
    // Producer.
    func track(_ body: TrackBody) async throws -> TrackAckDTO
    // Directed shares.
    func startShare(_ body: StartShareBody) async throws -> ShareDTO
    func stopShare(id: UUID) async throws
    func stopAllShares() async throws -> CountDTO
    func shares() async throws -> SharesDTO
    // Breadcrumb trail / history.
    func points(ownerId: UUID, since: Int64?, before: Int64?, limit: Int?) async throws -> PointsDTO
    func clearHistory(before: Int64?) async throws -> CountDTO
    // Social-graph directory.
    func contacts() async throws -> [TraxContact]
    /// The caller's own identity from the people directory (for the self-marker).
    func me() async throws -> TraxContact
}

/// REST transport against mvTrax. A value type whose members are all Sendable, so
/// it's `Sendable` with no `@unchecked`. The token provider is `@Sendable` +
/// `async` — the host supplies the current mvServer access token; it's invoked
/// off the caller's actor.
public struct HTTPTraxTransport: TraxTransport {
    public let baseURL: URL
    public let tokenProvider: @Sendable () async -> String?
    private let session: URLSession

    public init(baseURL: URL,
                tokenProvider: @escaping @Sendable () async -> String?,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session
    }

    // MARK: - Feed

    public func feed(since: Int64?, limit: Int?) async throws -> FeedDTO {
        var q: [URLQueryItem] = []
        if let since { q.append(.init(name: "since", value: String(since))) }
        if let limit { q.append(.init(name: "limit", value: String(limit))) }
        return try await get("/v0/feed", query: q)
    }

    // MARK: - Producer

    public func track(_ body: TrackBody) async throws -> TrackAckDTO {
        try await send("POST", "/v0/track", body: body)
    }

    // MARK: - Shares

    public func startShare(_ body: StartShareBody) async throws -> ShareDTO {
        try await send("POST", "/v0/shares", body: body)
    }

    public func stopShare(id: UUID) async throws {
        try await sendNoContent("DELETE", "/v0/shares/\(id)")
    }

    public func stopAllShares() async throws -> CountDTO {
        try await send("POST", "/v0/shares/stop-all", body: EmptyBody())
    }

    public func shares() async throws -> SharesDTO {
        try await get("/v0/shares", query: [])
    }

    // MARK: - Trail

    public func points(ownerId: UUID, since: Int64?, before: Int64?, limit: Int?) async throws -> PointsDTO {
        var q: [URLQueryItem] = []
        if let since { q.append(.init(name: "since", value: String(since))) }
        if let before { q.append(.init(name: "before", value: String(before))) }
        if let limit { q.append(.init(name: "limit", value: String(limit))) }
        return try await get("/v0/track/\(ownerId)/points", query: q)
    }

    public func clearHistory(before: Int64?) async throws -> CountDTO {
        var q: [URLQueryItem] = []
        if let before { q.append(.init(name: "before", value: String(before))) }
        return try await getDelete("/v0/track/history", query: q)
    }

    // MARK: - Directory

    public func contacts() async throws -> [TraxContact] {
        let res: ContactsDTO = try await get("/v0/contacts", query: [])
        return res.contacts
    }

    public func me() async throws -> TraxContact {
        try await get("/v0/me", query: [])
    }

    // MARK: - Plumbing

    private struct EmptyBody: Encodable {}

    private func get<Res: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Res {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        comps?.queryItems = query.isEmpty ? nil : query
        guard let url = comps?.url else { throw TraxTransportError.network("bad url \(path)") }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return try await perform(req)
    }

    /// DELETE with a query string and a decoded body (clear-history returns a count).
    private func getDelete<Res: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Res {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        comps?.queryItems = query.isEmpty ? nil : query
        guard let url = comps?.url else { throw TraxTransportError.network("bad url \(path)") }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        return try await perform(req)
    }

    private func send<Body: Encodable, Res: Decodable>(_ method: String, _ path: String, body: Body) async throws -> Res {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return try await perform(req)
    }

    private func sendNoContent(_ method: String, _ path: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        _ = try await rawData(req)
    }

    private func perform<Res: Decodable>(_ request: URLRequest) async throws -> Res {
        let data = try await rawData(request)
        do {
            return try JSONDecoder().decode(Res.self, from: data)
        } catch {
            throw TraxTransportError.decoding("\(Res.self): \(error)")
        }
    }

    /// Adds auth, executes, and maps non-2xx into a `TraxError` (preferred) or
    /// `TraxTransportError`. Returns the raw 2xx body.
    private func rawData(_ request: URLRequest) async throws -> Data {
        var req = request
        guard let token = await tokenProvider(), !token.isEmpty else {
            throw TraxTransportError.notAuthenticated
        }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw TraxTransportError.network(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw TraxTransportError.badResponse(status: -1)
        }
        guard (200...299).contains(http.statusCode) else {
            if var te = try? JSONDecoder().decode(TraxError.self, from: data) {
                te.httpStatus = http.statusCode
                throw te
            }
            throw TraxTransportError.badResponse(status: http.statusCode)
        }
        return data
    }
}
