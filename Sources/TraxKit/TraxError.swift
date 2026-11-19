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

    public init(error: Detail, httpStatus: Int? = nil) {
        self.error = error
        self.httpStatus = httpStatus
    }

    /// Worth trying again later (the server is unavailable, slow, overloaded or
    /// failed internally, or the token is being refreshed), as opposed to a
    /// refusal that will repeat (invalid, not found, forbidden, exists…).
    public var isRetryable: Bool {
        switch code {
        case "unavailable", "deadline_exceeded", "resource_exhausted", "aborted",
             "unknown", "internal", "unauthenticated":
            return true
        default:
            return false
        }
    }

    /// The HTTP status a Connect error code travels as (Connect protocol spec).
    static func httpStatus(forCode code: String) -> Int {
        switch code {
        case "canceled": return 499
        case "invalid_argument", "failed_precondition", "out_of_range": return 400
        case "unauthenticated": return 401
        case "permission_denied": return 403
        case "not_found": return 404
        case "already_exists", "aborted": return 409
        case "resource_exhausted": return 429
        case "unimplemented": return 501
        case "unavailable": return 503
        case "deadline_exceeded": return 504
        default: return 500   // unknown, internal, data_loss
        }
    }
}

extension TraxTransportError {
    /// Worth trying again later (no token yet, network trouble, a 5xx/429).
    public var isRetryable: Bool {
        switch self {
        case .notAuthenticated, .network: return true
        case .badResponse(let status): return status >= 500 || status == 429
        case .decoding: return false
        }
    }
}

/// Whether a failed call is worth retrying (unrecognised errors are not).
func isRetryable(_ error: Error) -> Bool {
    if let e = error as? TraxError { return e.isRetryable }
    if let e = error as? TraxTransportError { return e.isRetryable }
    if let e = error as? URLError { return e.code != .cancelled }
    return false
}

/// Transport-level failures that aren't a structured `TraxError` body.
public enum TraxTransportError: Error, Sendable, Equatable {
    case notAuthenticated          // no token available
    case badResponse(status: Int)  // non-2xx without a decodable error body
    case decoding(String)          // response didn't match the expected DTO
    case network(String)           // URLSession failure
}
