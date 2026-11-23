import Foundation
import ShellKit
import SwiftGit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif
#if os(Windows)
import WinSDK
#endif

extension GitCommand {

    /// git's usage line (`git_usage_string`), which it prints after a
    /// leading option it can't take.
    static let usageLines = [
        "usage: git [-v | --version] [-h | --help] [-C <path>] [-c <name>=<value>]",
        "           [--exec-path[=<path>]] [--html-path] [--man-path] [--info-path]",
        "           [-p | --paginate | -P | --no-pager] [--no-replace-objects] [--no-lazy-fetch]",
        "           [--no-optional-locks] [--no-advice] [--bare] [--git-dir=<path>]",
        "           [--work-tree=<path>] [--namespace=<name>] [--config-env=<name>=<envvar>]",
        "           <command> [<args>]"
    ]

    /// Runs one `git` invocation: `arguments` (argv without `argv[0]`) with
    /// its leading `-C <path>` and `-c <name>[=<value>]` taken as git's
    /// `handle_options` takes them, in order and each a separate word,
    /// stopping at the first other word. `body` gets the rest, preprocessed
    /// (``preprocess(_:)``), and runs with a copy of `Shell.current` that
    /// holds them for this invocation only: the working directory `-C`
    /// leads to, and `-c`'s entries added to `GIT_CONFIG_PARAMETERS`. The
    /// process' own directory and environment are never changed.
    ///
    /// Shared by every entry path, the standalone binary (`Entry`) and the
    /// embedded shellkit face (`SwiftPortsCommands`). An option without its
    /// operand, or a directory that can't be entered, throws git's words as
    /// a ``CLIError``; a directory a sandbox refuses, its denial.
    package static func withInvocation<T: Sendable>(
        _ arguments: [String], _ body: @Sendable ([String]) async throws -> T
    ) async throws -> T {
        let shell = Shell.current.copy()
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let option = arguments[index]
            guard option == "-C" || option == "-c" else { break }
            guard index + 1 < arguments.endIndex else {
                let complaint = option == "-C"
                    ? "no directory given for '-C' option" : "-c expects a configuration string"
                throw CLIError.stderr([complaint] + usageLines, exitCode: 129)
            }
            let operand = arguments[index + 1]
            if option == "-C" {
                if !operand.isEmpty {
                    shell.environment.workingDirectory = try await changeDirectory(to: operand, in: shell)
                }
            } else {
                shell.environment["GIT_CONFIG_PARAMETERS"] = GitConfigParameters.push(
                    operand, onto: shell.environment["GIT_CONFIG_PARAMETERS"])
            }
            index += 2
        }
        let rest = preprocess(Array(arguments[index...]))
        return try await shell.withCurrent { try await body(rest) }
    }

    /// The working directory `chdir(operand)` would leave `shell` in: the
    /// operand from its working directory, followed on disk (symlinks, then
    /// `..`) as the kernel does, or on Windows as Git for Windows'
    /// `mingw_chdir` does (the final path of a symlink or junction), for the
    /// next `-C` to start from. One that can't be entered is git's
    /// `fatal: cannot change to '<operand>'`. A sandbox sees both the path
    /// asked for and the one it leads to.
    private static func changeDirectory(to operand: String, in shell: Shell) async throws -> String {
        let requested = shell.resolve(operand)
        try await shell.sandbox?.authorize(requested)
        let physical: String
        #if os(Windows)
        physical = try finalPath(of: requested.path, operand: operand)
        #else
        let path = requested.path
        var status = stat()
        guard stat(path, &status) == 0 else {
            throw cannotChange(to: operand, reason: String(cString: strerror(errno)))
        }
        // S_ISDIR, spelled out: S_IFMT / S_IFDIR import with different
        // types per C library.
        guard status.st_mode & 0o170000 == 0o040000 else {
            throw cannotChange(to: operand, reason: String(cString: strerror(ENOTDIR)))
        }
        guard access(path, X_OK) == 0 else {
            throw cannotChange(to: operand, reason: String(cString: strerror(errno)))
        }
        guard let resolved = realpath(path, nil) else {
            throw cannotChange(to: operand, reason: String(cString: strerror(errno)))
        }
        defer { free(resolved) }
        physical = String(cString: resolved)
        #endif
        if physical != requested.path {
            try await shell.sandbox?.authorize(URL(fileURLWithPath: physical, isDirectory: true))
        }
        return shell.displayPath(for: physical)
    }

    #if os(Windows)
    /// `mingw_chdir`: the directory opened (`FILE_FLAG_BACKUP_SEMANTICS`),
    /// its final path (`GetFinalPathNameByHandleW`) with the NT prefixes
    /// `normalize_ntpath` strips, in forward slashes.
    private static func finalPath(of path: String, operand: String) throws -> String {
        let share = DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE)
        let handle = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, 0, share, nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw cannotChange(to: operand, reason: windowsReason(GetLastError()))
        }
        defer { CloseHandle(handle) }
        var information = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &information) else {
            throw cannotChange(to: operand, reason: windowsReason(GetLastError()))
        }
        // `SetCurrentDirectoryW` refuses a file with ERROR_DIRECTORY.
        guard information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 else {
            throw cannotChange(to: operand, reason: windowsReason(DWORD(ERROR_DIRECTORY)))
        }
        let size = GetFinalPathNameByHandleW(handle, nil, 0, 0)
        var buffer = [WCHAR](repeating: 0, count: Int(size) + 1)
        let length = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), 0)
        guard size > 0, length > 0, Int(length) < buffer.count else {
            throw cannotChange(to: operand, reason: windowsReason(GetLastError()))
        }
        var target = String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
        if target.hasPrefix("\\??\\") || target.hasPrefix("\\\\?\\") {
            target.removeFirst(4)
        } else if target.lowercased().hasPrefix("\\dosdevices\\") {
            target.removeFirst(12)
        }
        if target.lowercased().hasPrefix("unc\\") {
            target = "\\" + target.dropFirst(3)
        }
        return target.replacingOccurrences(of: "\\", with: "/")
    }

    /// `strerror(err_win_to_posix(error))` for what opening a path returns.
    private static func windowsReason(_ error: DWORD) -> String {
        let code: Int32
        switch error {
        case DWORD(ERROR_FILE_NOT_FOUND), DWORD(ERROR_PATH_NOT_FOUND), DWORD(ERROR_BAD_PATHNAME):
            code = ENOENT
        case DWORD(ERROR_ACCESS_DENIED), DWORD(ERROR_SHARING_VIOLATION), DWORD(ERROR_LOCK_VIOLATION):
            code = EACCES
        case DWORD(ERROR_FILENAME_EXCED_RANGE):
            code = ENAMETOOLONG
        case DWORD(ERROR_INVALID_NAME), DWORD(ERROR_DIRECTORY), DWORD(ERROR_NOT_A_REPARSE_POINT):
            code = EINVAL
        case DWORD(ERROR_INVALID_DRIVE):
            code = ENODEV
        case DWORD(ERROR_NOT_READY):
            code = EAGAIN
        default:
            code = ENOSYS
        }
        return String(cString: strerror(code))
    }
    #endif

    private static func cannotChange(to operand: String, reason: String) -> CLIError {
        CLIError.stderr("fatal: cannot change to '\(operand)': \(reason)", exitCode: 128)
    }
}
