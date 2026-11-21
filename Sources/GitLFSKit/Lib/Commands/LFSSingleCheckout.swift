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
#elseif os(Windows)
import ucrt
import WinSDK
#endif

/// `commands/pull.go` (`singleCheckout`, `gitIndexer`), `lfs/gitfilter_smudge.go`
/// (`SmudgeToFile`), and `tools/dir_walker.go` (`DirWalker`).
struct LFSSingleCheckout {
    private static let chunkSize = 65_536

    struct DownloadDeclinedError: Error, CustomStringConvertible {
        var description: String { "smudge filter: content not local" }
    }

    struct CheckoutIOError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private enum ParentWalkOutcome {
        case present
        case missing
        case failed(String)
    }

    let git: GitClient
    let store: LocalStore
    let workingDirectory: URL?
    let skip: Bool
    let referenceDirectories: [String]
    var stderr = ""
    private var updatedPaths: [String] = []
    private var stagedDeletions: Set<String>?

    static func make(
        git: GitClient, store: LocalStore, repository: LFSRepository, configuration: LFSConfiguration
    ) async throws -> LFSSingleCheckout {
        let clean = try await git.configGet("filter.lfs.clean") ?? ""
        let paths = await LFSRepositoryPaths.load(git, configuration: configuration)
        return LFSSingleCheckout(
            git: git, store: store, workingDirectory: repository.workingDirectory,
            skip: clean.isEmpty, referenceDirectories: paths.references.map {
                URL(fileURLWithPath: $0, relativeTo: git.workingDirectory).path
            })
    }

    /// Checks out one pointer to its repo-relative path, leaving modified
    /// files, symlinks, conflicting directories, and staged deletions untouched.
    mutating func run(_ wrapped: WrappedPointer) async {
        guard !skip, let root = workingDirectory else { return }
        let walk = await walkParents(of: wrapped.name, in: root, create: false)
        var missing = false
        switch walk {
        case .present: break
        case .missing: missing = true
        case .failed(let message):
            stderr += "Checkout error trying to check path for \(wrapped.name.goQuoted): \(message)\n"
            return
        }

        let fileURL = root.appendingPathComponent(wrapped.name)
        if !missing {
            switch await inspectWorktreeFile(fileURL, expectedOID: wrapped.pointer.oid, name: wrapped.name) {
            case .replace: break
            case .missing: missing = true
            case .keep: return
            case .failed(let message):
                stderr += "Checkout error for \(wrapped.name.goQuoted): \(message)\n"
                return
            }
        }

        if missing {
            switch await isStagedDeletion(wrapped.name) {
            case .success(true): return
            case .success(false): break
            case .failure(let error):
                stderr += "Checkout error trying to run diff-index: \(error)\n"
                return
            }
            if case .failed(let message) = await walkParents(of: wrapped.name, in: root, create: true) {
                stderr += "Checkout error trying to create path for \(wrapped.name.goQuoted): \(message)\n"
                return
            }
        }

        do {
            try await runToPath(wrapped, to: fileURL, displayPath: wrapped.name)
            updatedPaths.append(wrapped.name)
        } catch is DownloadDeclinedError {
            stderr += "Skipped checkout for \(wrapped.name.goQuoted), content not local. Use fetch to download.\n"
        } catch {
            stderr += "could not check out \(wrapped.name.goQuoted): \(error)\n"
        }
    }

    /// `SmudgeToFile` with `download == false`: writes local content to
    /// `destination`, or writes the canonical pointer and throws
    /// ``DownloadDeclinedError`` when the object is not in local storage.
    ///
    /// On Windows the bytes are written to a new file in the same directory
    /// and that name replaces `destination`. Truncating the existing file
    /// would rewrite every hard link that shares it. POSIX `unlink` followed
    /// by `O_EXCL` already creates a new inode, which is what git-lfs does.
    func runToPath(_ wrapped: WrappedPointer, to destination: URL, displayPath: String) async throws {
        guard !skip else { return }
        try await Shell.authorize(destination)
        let existing = Self.lstatInfo(destination.path)
        if let existing, existing.isRegular, wrapped.pointer.size == 0, existing.size == 0 {
            return
        }
        let mode: UInt32 = (existing?.isRegular == true) ? existing!.permissions : 0o666
        let output = try await openCheckoutFile(replacing: destination, displayPath: displayPath, mode: mode)
        defer { output.discard() }
        if wrapped.pointer.size != 0 {
            guard let mediaURL = try await locateLocalObject(
                oid: wrapped.pointer.oid, size: wrapped.pointer.size
            ) else {
                try output.handle.write(contentsOf: Data(wrapped.pointer.encoded.utf8))
                try output.commit(displayPath: displayPath)
                throw DownloadDeclinedError()
            }
            do {
                try Self.copyStream(from: mediaURL, to: output.handle)
            } catch {
                throw CheckoutIOError("could not write working directory file: \(error)")
            }
        }
        try output.commit(displayPath: displayPath)
    }

    /// `gitIndexer.Close`: refreshes stat cache for all checked-out paths once.
    mutating func close() async {
        guard !skip, !updatedPaths.isEmpty else { return }
        let paths = updatedPaths
        updatedPaths = []
        do {
            try await git.refreshIndex(paths: paths)
        } catch {
            stderr += "Error updating the Git index:\n\(error)\n"
        }
    }

    private enum InspectionOutcome {
        case replace
        case missing
        case keep
        case failed(String)
    }

    private func inspectWorktreeFile(
        _ fileURL: URL, expectedOID: String, name: String
    ) async -> InspectionOutcome {
        do {
            try await Shell.authorize(fileURL)
        } catch {
            return .failed(String(describing: error))
        }
        let statResult = Self.lstatResult(fileURL.path)
        let info: FileLStat
        switch statResult {
        case .found(let value): info = value
        case .missing: return .missing
        case .error(let code):
            return .failed("lstat \(name): \(Self.posixMessage(code))")
        }
        if !info.isRegular {
            if info.isDirectory { return .keep }
            return .failed(PointerError.notARegularFile(name).description)
        }
        guard info.size < Int64(Pointer.blobSizeCutoff) else { return .keep }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .failed(lfsFileError(error, path: name))
        }
        let decoded: Pointer
        do {
            decoded = try Pointer.decode(data)
        } catch let error as PointerError {
            if error.isNotAPointer { return .keep }
            if case .badPointerKey = error { return .keep }
            return .failed(error.description)
        } catch {
            return .failed(String(describing: error))
        }
        return decoded.oid == expectedOID ? .replace : .keep
    }

    private mutating func isStagedDeletion(_ path: String) async -> Result<Bool, any Error> {
        if let cached = stagedDeletions { return .success(cached.contains(path)) }
        do {
            let entries = try await git.diffIndex(ref: "HEAD", cached: true)
            var deleted = Set<String>()
            for entry in entries
            where entry.status == "D" && entry.newMode == 0
                && (entry.oldMode == 0o100644 || entry.oldMode == 0o100755) {
                deleted.insert(entry.sourcePath)
            }
            stagedDeletions = deleted
            return .success(deleted.contains(path))
        } catch {
            return .failure(error)
        }
    }

    private func walkParents(of filePath: String, in root: URL, create: Bool) async -> ParentWalkOutcome {
        let components = filePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count > 1 else { return .present }
        let parentComponents = components.dropLast()
        let parentJoined = parentComponents.joined(separator: "/")
        var currentRel = ""
        for part in parentComponents {
            if part.isEmpty || part == "." || part == ".." {
                let message = "invalid directory \(part.goQuoted) in path: \(parentJoined.goQuoted)\ninvalid directory"
                return .failed(message)
            }
            currentRel = currentRel.isEmpty ? part : "\(currentRel)/\(part)"
            let url = root.appendingPathComponent(currentRel)
            do {
                try await Shell.authorize(url)
            } catch {
                return .failed(String(describing: error))
            }
            switch Self.lstatResult(url.path) {
            case .found(let info):
                if !info.isDirectory {
                    return .failed("not a directory: \(currentRel.goQuoted)\nnot a directory")
                }
            case .missing:
                guard create else { return .missing }
                do {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                } catch {
                    return .failed(lfsFileError(error, path: currentRel, operation: "mkdir"))
                }
            case .error(let code):
                return .failed("lstat \(currentRel): \(Self.posixMessage(code))")
            }
        }
        return .present
    }

    private func locateLocalObject(oid: String, size: Int64) async throws -> URL? {
        let media = store.objectPathname(oid)
        try await Shell.authorize(media)
        if let info = Self.statSize(media.path) {
            if info == size { return media }
            try? FileManager.default.removeItem(at: media)
        }
        try? await store.linkOrCopyFromReference(oid, size: size, directories: referenceDirectories)
        return try await store.objectExists(oid, size: size) ? media : nil
    }

    private static func copyStream(from source: URL, to destination: FileHandle) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        while true {
            guard let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try destination.write(contentsOf: chunk)
        }
    }

    private struct FileLStat {
        let isRegular: Bool
        let isDirectory: Bool
        let size: Int64
        let permissions: UInt32
    }

    private enum LStatResult {
        case found(FileLStat)
        case missing
        case error(Int32)
    }

    private static func lstatInfo(_ path: String) -> FileLStat? {
        if case .found(let info) = lstatResult(path) { return info }
        return nil
    }

    private static func statSize(_ path: String) -> Int64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    private static func lstatResult(_ path: String) -> LStatResult {
        #if os(Windows)
        var data = WIN32_FILE_ATTRIBUTE_DATA()
        let found = path.withCString(encodedAs: UTF16.self) { name in
            withUnsafeMutablePointer(to: &data) { pointer in
                GetFileAttributesExW(name, GetFileExInfoStandard, UnsafeMutableRawPointer(pointer))
            }
        }
        guard found else {
            let err = GetLastError()
            if err == DWORD(ERROR_FILE_NOT_FOUND) || err == DWORD(ERROR_PATH_NOT_FOUND) { return .missing }
            return .error(Int32(bitPattern: err))
        }
        let attrs = data.dwFileAttributes
        let isLink = (attrs & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) != 0
        let isDir = !isLink && (attrs & DWORD(FILE_ATTRIBUTE_DIRECTORY)) != 0
        let isRegular = !isLink && !isDir
        let size = Int64((UInt64(data.nFileSizeHigh) << 32) | UInt64(data.nFileSizeLow))
        let readOnly = (attrs & DWORD(FILE_ATTRIBUTE_READONLY)) != 0
        return .found(FileLStat(isRegular: isRegular, isDirectory: isDir, size: size,
                                permissions: readOnly ? 0o444 : 0o666))
        #else
        var st = stat()
        let rc = path.withCString { lstat($0, &st) }
        guard rc == 0 else {
            let code = errno
            return (code == ENOENT || code == ENOTDIR) ? .missing : .error(code)
        }
        let type = st.st_mode & S_IFMT
        return .found(FileLStat(
            isRegular: type == S_IFREG, isDirectory: type == S_IFDIR,
            size: Int64(st.st_size), permissions: UInt32(st.st_mode & 0o777)))
        #endif
    }
}

extension LFSSingleCheckout {
    /// Opens the file checkout will write. POSIX removes `destination` first
    /// and creates it with `O_EXCL`. Windows writes a sibling and
    /// ``CheckoutOutput/commit(displayPath:)`` renames it into place, so a
    /// hard link's other names keep the previous bytes.
    private func openCheckoutFile(
        replacing destination: URL, displayPath: String, mode: UInt32
    ) async throws -> CheckoutOutput {
        #if os(Windows)
        let output = URL(fileURLWithPath: Self.temporarySibling(of: destination.path))
        try await Shell.authorize(output)
        let handle = try Self.createExclusive(output.path, mode: mode, displayPath: displayPath)
        return CheckoutOutput(handle: handle, path: output.path, replaces: destination.path)
        #else
        try Self.removeIfPresent(destination.path, displayPath: displayPath)
        let handle = try Self.createExclusive(destination.path, mode: mode, displayPath: displayPath)
        return CheckoutOutput(handle: handle, path: destination.path, replaces: nil)
        #endif
    }

    #if os(Windows)
    private static func temporarySibling(of path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = ".\(url.lastPathComponent).lfs-checkout-\(UUID().uuidString)"
        return url.deletingLastPathComponent().appendingPathComponent(name).path
    }

    /// `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING`: the destination name
    /// now refers to `source`, and any other hard link keeps the old file.
    private static func commitReplacement(
        _ source: String, _ destination: String, displayPath: String
    ) throws {
        if let info = lstatInfo(destination), info.permissions & 0o200 == 0 {
            _ = destination.withCString(encodedAs: UTF16.self) {
                SetFileAttributesW($0, DWORD(FILE_ATTRIBUTE_NORMAL))
            }
        }
        let moved = source.withCString(encodedAs: UTF16.self) { from in
            destination.withCString(encodedAs: UTF16.self) { to in
                MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING))
            }
        }
        guard moved else {
            throw CheckoutIOError(
                "could not create working directory file \(displayPath.goQuoted): "
                    + "open \(destination): \(openFailure(GetLastError()))")
        }
    }
    #else
    private static func removeIfPresent(_ path: String, displayPath: String) throws {
        let rc = path.withCString { unlink($0) }
        if rc != 0 {
            let code = errno
            if code == ENOENT { return }
            throw CheckoutIOError(
                "could not remove working directory file \(displayPath.goQuoted): "
                    + "remove \(path): \(posixMessage(code))")
        }
    }
    #endif

    /// The file `runToPath` writes. `commit` publishes it at the checkout
    /// path; `discard` drops a Windows temporary file that was never published.
    private final class CheckoutOutput {
        let handle: FileHandle
        #if os(Windows)
        private let path: String
        #endif
        private let replaces: String?
        private var closed = false
        private var committed = false

        init(handle: FileHandle, path: String, replaces: String?) {
            self.handle = handle
            self.replaces = replaces
            #if os(Windows)
            self.path = path
            #else
            _ = path
            #endif
        }

        func commit(displayPath: String) throws {
            try closeHandle()
            #if os(Windows)
            if let replaces {
                try LFSSingleCheckout.commitReplacement(path, replaces, displayPath: displayPath)
            }
            #endif
            committed = true
        }

        func discard() {
            try? closeHandle()
            #if os(Windows)
            guard !committed, replaces != nil else { return }
            try? FileManager.default.removeItem(atPath: path)
            #endif
        }

        private func closeHandle() throws {
            guard !closed else { return }
            closed = true
            try handle.close()
        }
    }

    private static func createExclusive(_ path: String, mode: UInt32, displayPath: String) throws -> FileHandle {
        #if os(Windows)
        // `_wopen` is variadic and unavailable. `O_WRONLY|O_CREAT|O_EXCL|O_BINARY`
        // is a binary `CREATE_NEW` with write access and `_SH_DENYNO` sharing.
        // A mode without the write bit is read-only, as `_wopen`'s `pmode` is.
        // The CRT descriptor owns the handle, as it does for `GIT_LFS_PROGRESS`.
        let attributes = (mode & 0o200) == 0
            ? DWORD(FILE_ATTRIBUTE_READONLY) : DWORD(FILE_ATTRIBUTE_NORMAL)
        let handle = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil,
                        DWORD(CREATE_NEW), attributes, nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            let reason = openFailure(GetLastError())
            throw CheckoutIOError(
                "could not create working directory file \(displayPath.goQuoted): "
                    + "open \(path): \(reason)")
        }
        // Flags 0: binary, not `_O_TEXT`. `_O_BINARY` is not a valid argument here.
        let descriptor = _open_osfhandle(Int(bitPattern: handle), 0)
        guard descriptor >= 0 else {
            let code = errno
            CloseHandle(handle)
            throw CheckoutIOError(
                "could not create working directory file \(displayPath.goQuoted): "
                    + "open \(path): \(posixMessage(code))")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        #else
        let descriptor = path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode)) }
        guard descriptor >= 0 else {
            throw CheckoutIOError(
                "could not create working directory file \(displayPath.goQuoted): "
                    + "open \(path): \(posixMessage(errno))")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        #endif
    }

    #if os(Windows)
    /// Words for a `CreateFileW` failure, in the same form as ``posixMessage(_:)``.
    private static func openFailure(_ error: DWORD) -> String {
        switch Int32(error) {
        case ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND: return "no such file or directory"
        case ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION: return "permission denied"
        case ERROR_DIRECTORY: return "is a directory"
        case ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS: return "File exists"
        default: return "Input/output error"
        }
    }
    #endif

    private static func posixMessage(_ code: Int32) -> String {
        switch code {
        case ENOENT: return "no such file or directory"
        case EACCES, EPERM: return "permission denied"
        case EISDIR: return "is a directory"
        case ENOTDIR: return "not a directory"
        default: return String(cString: strerror(code))
        }
    }
}
