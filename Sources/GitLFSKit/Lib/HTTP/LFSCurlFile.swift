#if os(Windows)
import Foundation
import WinSDK

/// One synchronous handle per curl upload worker, including its redirect rewinds.
/// Avoids Foundation's healthy InputStream.streamError nil-unwrapping trap.
final class LFSCurlFile {
    private let handle: HANDLE
    let length: Int64

    init(url: URL) throws {
        guard url.isFileURL else { throw URLError(.cannotOpenFile) }
        let handle = url.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw Self.failure() }
        var size = LARGE_INTEGER()
        guard GetFileSizeEx(handle, &size) else {
            let error = Self.failure()
            CloseHandle(handle)
            throw error
        }
        self.handle = handle
        length = size.QuadPart
    }

    deinit { CloseHandle(handle) }

    func read(_ buffer: UnsafeMutablePointer<UInt8>, count: Int) throws -> Int {
        var amount: DWORD = 0
        let requested = DWORD(clamping: min(count, 64 * 1024))
        guard ReadFile(handle, buffer, requested, &amount, nil) else { throw Self.failure() }
        return Int(amount)
    }

    func seek(to offset: Int64) throws {
        guard offset >= 0, offset <= length else { throw URLError(.cannotOpenFile) }
        var position = LARGE_INTEGER()
        position.QuadPart = offset
        guard SetFilePointerEx(handle, position, nil, DWORD(FILE_BEGIN)) else { throw Self.failure() }
    }

    private static func failure() -> URLError {
        let code = GetLastError()
        return URLError(.cannotOpenFile, userInfo: [NSLocalizedDescriptionKey: "Windows error \(code)"])
    }
}
#endif
