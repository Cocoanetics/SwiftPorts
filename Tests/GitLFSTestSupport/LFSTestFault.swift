import Foundation

/// A fault the in-process server applies to a later request.
///
/// Status faults (``unauthorized``, ``tooManyRequests(_:)``, ``serverError(_:)``)
/// answer the next request and are then spent. The others stay on one object
/// until the batch or `GET` they affect.
public enum LFSTestFault: Sendable, Equatable {
    /// The next request is answered `401`.
    case unauthorized
    /// The batch object for `oid` carries `error.code` (404, 410, or 422).
    case objectStatus(oid: String, code: Int)
    /// The next request is answered `429` with this `Retry-After` value.
    case tooManyRequests(retryAfter: String)
    /// The next request is answered with this 5xx status.
    case serverError(Int)
    /// This object's transfer actions use an `expires_at` already in the past.
    case expired(oid: String)
    /// `GET` returns a body whose length is not the stored object's size.
    case wrongSize(oid: String)
    /// `GET` returns a body whose SHA-256 is not the object id.
    /// A non-empty body keeps its length. The empty object grows by one byte,
    /// because the empty digest is unique.
    case wrongSHA256(oid: String)

    /// Token written on the ``LFSRecordedRequest`` this fault shapes.
    public var logToken: String {
        switch self {
        case .unauthorized:
            return "401"
        case .objectStatus(_, let code):
            return String(code)
        case .tooManyRequests:
            return "429"
        case .serverError(let code):
            return String(code)
        case .expired:
            return "expired"
        case .wrongSize:
            return "size"
        case .wrongSHA256:
            return "sha256"
        }
    }

    var oid: String? {
        switch self {
        case .unauthorized, .tooManyRequests, .serverError:
            return nil
        case .objectStatus(let oid, _), .expired(let oid), .wrongSize(let oid), .wrongSHA256(let oid):
            return oid
        }
    }

    var isStatusFault: Bool {
        switch self {
        case .unauthorized, .tooManyRequests, .serverError:
            return true
        case .objectStatus, .expired, .wrongSize, .wrongSHA256:
            return false
        }
    }
}

/// One request the server answered, in the order it finished them.
public struct LFSRecordedRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let status: Int
    /// Header names are lowercased.
    public let requestHeaders: [String: String]
    /// Header names are lowercased.
    public let responseHeaders: [String: String]
    public let requestBody: Data
    public let responseBody: Data
    /// ``LFSTestFault/logToken`` when an injected fault shaped this response.
    public let fault: String?
}
