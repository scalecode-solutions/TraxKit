import Foundation

/// The structured error envelope mvTrax returns: `{ "error": { code, reason?, message } }`.
public struct TraxError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public struct Detail: Codable, Sendable, Equatable {
        public let code: String
        public let reason: String?
        public let message: String
    }
    public let error: Detail
    /// The HTTP status that carried this error (set by the transport; not on the wire).
    public var httpStatus: Int?

    enum CodingKeys: String, CodingKey { case error }

    public var code: String { error.code }
    public var reason: String? { error.reason }
    public var message: String { error.message }

    public var description: String {
        "TraxError(status: \(httpStatus.map(String.init) ?? "?"), code: \(code), reason: \(reason ?? "-"), message: \(message))"
    }
}

/// Transport-level failures that aren't a structured `TraxError` body.
public enum TraxTransportError: Error, Sendable, Equatable {
    case notAuthenticated          // no token available
    case badResponse(status: Int)  // non-2xx without a decodable error body
    case decoding(String)          // response didn't match the expected DTO
    case network(String)           // URLSession failure
}
