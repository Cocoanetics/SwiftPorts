import Foundation
import libgit2

/// Wraps a non-zero return code from a `git_*` C call.
///
/// libgit2 stores the actual error message in thread-local state via
/// `git_error_last()`; we snapshot it at throw time so the `Error` is
/// safe to hand off across threads.
public struct Libgit2Error: Error, LocalizedError, Sendable {
    public let code: Int32
    public let klass: Int32
    public let message: String

    public var errorDescription: String? {
        "libgit2 error (\(code)/\(klass)): \(message)"
    }

    static func last(code: Int32) -> Libgit2Error {
        if let raw = git_error_last(), let msg = raw.pointee.message {
            return Libgit2Error(
                code: code,
                klass: raw.pointee.klass,
                message: String(cString: msg))
        }
        return Libgit2Error(code: code, klass: 0, message: "unknown error")
    }
}

/// Throws ``Libgit2Error`` if `rc < 0`. Returns `rc` otherwise so the
/// caller can use it (some libgit2 APIs return the count on success).
@discardableResult
func check(_ rc: Int32) throws -> Int32 {
    if rc < 0 { throw Libgit2Error.last(code: rc) }
    return rc
}
