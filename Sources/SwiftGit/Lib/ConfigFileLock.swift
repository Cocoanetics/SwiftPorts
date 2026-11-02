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
import WinSDK
#endif

/// git's lock on a config file it rewrites (`hold_lock_file_for_update`):
/// `<file>.lock`, made exclusively next to the file a symlink points at,
/// then either written and renamed over the file (`commit_lock_file`) or
/// removed (`rollback_lock_file`). Taking it fails as git's does, with
/// `strerror`'s words: `File exists` for a lock another process holds,
/// `Permission denied`, `No such file or directory`, `Not a directory`.
struct ConfigFileLock {
    /// The file itself, with symlinks resolved as git's `resolve_symlink`
    /// does, so the lock sits by it and the rename replaces it, not a link.
    let target: String
    /// `<target>.lock`.
    let lockPath: String
    #if os(Windows)
    private let handle: HANDLE
    #else
    private let descriptor: Int32
    #endif

    /// Where the lock of a config file at `path` goes: by the file a
    /// symlink names, as git puts it; a path that isn't there resolves
    /// as far as it goes.
    static func resolvedTarget(of path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Takes the lock, or throws git's `error: could not lock config file
    /// <named>: <reason>` (status 255).
    init(path: String, named: String) throws {
        target = Self.resolvedTarget(of: path)
        lockPath = target + ".lock"
        #if os(Windows)
        let handle = lockPath.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard handle != INVALID_HANDLE_VALUE else {
            throw Self.failure(named: named, reason: Self.reason(for: GetLastError()))
        }
        self.handle = handle
        #else
        let descriptor = open(lockPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else {
            throw Self.failure(named: named, reason: String(cString: strerror(errno)))
        }
        self.descriptor = descriptor
        #endif
    }

    private static func failure(named: String, reason: String) -> GitDiagnosticError {
        GitDiagnosticError(lines: ["error: could not lock config file \(named): \(reason)"], exitCode: 255)
    }

    /// Writes `bytes` to the lock, gives it the file's own mode, and
    /// renames it over the file. On failure the lock is removed and git's
    /// `error: could not write config file <named>: <reason>` (status 4)
    /// thrown.
    func commit(_ bytes: [UInt8], named: String) throws {
        #if os(Windows)
        var failure: String?
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                var written: DWORD = 0
                let chunk = DWORD(buffer.count - offset)
                guard WriteFile(handle, buffer.baseAddress! + offset, chunk, &written, nil) else {
                    failure = Self.reason(for: GetLastError())
                    return
                }
                offset += Int(written)
            }
        }
        CloseHandle(handle)
        if failure == nil {
            let moved = lockPath.withCString(encodedAs: UTF16.self) { lock in
                target.withCString(encodedAs: UTF16.self) { file in
                    MoveFileExW(lock, file, DWORD(MOVEFILE_REPLACE_EXISTING))
                }
            }
            if !moved { failure = Self.reason(for: GetLastError()) }
        }
        if let failure {
            _ = lockPath.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
            throw GitDiagnosticError(lines: ["error: could not write config file \(named): \(failure)"], exitCode: 4)
        }
        #else
        var failure: String?
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = String(cString: strerror(errno))
                    return
                }
                offset += written
            }
        }
        // The file's mode goes with it (git's chmod of the lock).
        var status = stat()
        if failure == nil, stat(target, &status) == 0, fchmod(descriptor, status.st_mode & 0o7777) != 0 {
            failure = String(cString: strerror(errno))
        }
        close(descriptor)
        if failure == nil, rename(lockPath, target) != 0 {
            failure = String(cString: strerror(errno))
        }
        if let failure {
            unlink(lockPath)
            throw GitDiagnosticError(lines: ["error: could not write config file \(named): \(failure)"], exitCode: 4)
        }
        #endif
    }

    /// Removes the lock, nothing written.
    func rollback() {
        #if os(Windows)
        CloseHandle(handle)
        _ = lockPath.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
        #else
        close(descriptor)
        unlink(lockPath)
        #endif
    }

    #if os(Windows)
    /// `strerror`'s words for what Windows says.
    private static func reason(for error: DWORD) -> String {
        switch Int32(error) {
        case ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS: return "File exists"
        case ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION: return "Permission denied"
        case ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND: return "No such file or directory"
        case ERROR_DIRECTORY: return "Not a directory"
        default: return "Input/output error"
        }
    }
    #endif
}
