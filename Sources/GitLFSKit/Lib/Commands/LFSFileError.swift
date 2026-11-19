import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif os(Windows)
import ucrt
#endif

/// The os.PathError wording used by git-lfs for filesystem failures.
func lfsFileError(_ error: Error, path: String, operation: String = "open") -> String {
    let nsError = error as NSError
    let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
    let posix = nsError.domain == NSPOSIXErrorDomain ? nsError.code : underlying?.code
    let reason: String
    if nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError || posix == Int(ENOENT) {
        reason = "no such file or directory"
    } else if nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError
                || posix == Int(EACCES) {
        reason = "permission denied"
    } else if posix == Int(EISDIR) {
        return "read \(path): is a directory"
    } else {
        reason = error.localizedDescription
    }
    return "\(operation) \(path): \(reason)"
}
