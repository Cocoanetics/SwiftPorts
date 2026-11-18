import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// Go's `os.Rename`: renames `source` to `destination` in one step,
/// replacing a file already there (`rename(2)`; `MoveFileExW` with
/// `MOVEFILE_REPLACE_EXISTING` on Windows). Throws the system's reason.
func renameReplacing(_ source: String, _ destination: String) throws {
    #if os(Windows)
    let moved = source.withCString(encodedAs: UTF16.self) { from in
        destination.withCString(encodedAs: UTF16.self) { to in
            MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING))
        }
    }
    guard moved else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination])
    }
    #else
    guard rename(source, destination) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    #endif
}
