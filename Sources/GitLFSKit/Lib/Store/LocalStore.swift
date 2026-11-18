import Foundation
import ShellKit
import SwiftGit

/// The repository's local Git LFS object store (git-lfs `fs/fs.go`,
/// `Filesystem`): `<lfs dir>/objects/<oid[0:2]>/<oid[2:4]>/<oid>`, with
/// `<lfs dir>/tmp` for files on their way in and `<lfs dir>/incomplete`
/// for downloads.
///
/// `<lfs dir>` is `lfs.storage` when set — a relative path resolved against
/// the git common dir — and `<git-common-dir>/lfs` otherwise, so every
/// linked worktree shares the main repository's store.
public struct LocalStore: Sendable {
    /// The git common dir (`GitStorageDir`).
    public let gitStorageDirectory: URL
    /// `<lfs dir>` (`LFSStorageDir`).
    public let storageDirectory: URL

    /// `fs.New`: the store under `gitStorageDirectory`, or at `storage`
    /// (`lfs.storage`) when given — an absolute path as is, a relative one
    /// against `gitStorageDirectory`.
    public init(gitStorageDirectory: URL, storage: String? = nil) {
        self.gitStorageDirectory = gitStorageDirectory
        let lfsDirectory = storage.flatMap { $0.isEmpty ? nil : $0 } ?? "lfs"
        if (lfsDirectory as NSString).isAbsolutePath {
            storageDirectory = URL(fileURLWithPath: lfsDirectory, isDirectory: true)
        } else {
            storageDirectory = gitStorageDirectory.appendingPathComponent(lfsDirectory, isDirectory: true)
        }
    }

    /// The store of the repository `client` works in: its common dir
    /// (`git rev-parse --git-common-dir`) and `lfs.storage`.
    public static func open(_ client: SwiftGit.GitClient) async throws -> LocalStore {
        guard let commonDir = try await client.commonDir() else {
            throw CocoaError(.fileNoSuchFile)
        }
        return LocalStore(
            gitStorageDirectory: URL(fileURLWithPath: commonDir, isDirectory: true),
            storage: try await client.configGet("lfs.storage"))
    }

    /// `<lfs dir>/objects`.
    public var objectsDirectory: URL {
        storageDirectory.appendingPathComponent("objects", isDirectory: true)
    }

    /// `<lfs dir>/tmp`.
    public var temporaryDirectory: URL {
        storageDirectory.appendingPathComponent("tmp", isDirectory: true)
    }

    /// `<lfs dir>/incomplete`, where downloads land before they're verified.
    public var incompleteDirectory: URL {
        storageDirectory.appendingPathComponent("incomplete", isDirectory: true)
    }

    /// Where object `oid` lives (`ObjectPathname`); `/dev/null` for the
    /// empty object.
    public func objectPathname(_ oid: String) -> URL {
        if oid == Pointer.emptyObjectSHA256 {
            return URL(fileURLWithPath: "/dev/null")
        }
        return localObjectDirectory(oid).appendingPathComponent(oid)
    }

    /// Where object `oid` lives, creating its directory (`ObjectPath`).
    public func objectPath(_ oid: String) async throws -> URL {
        guard oid.utf8.count >= 4 else { throw LocalStoreError.tooShortObjectID(oid) }
        if oid == Pointer.emptyObjectSHA256 {
            return URL(fileURLWithPath: "/dev/null")
        }
        let directory = localObjectDirectory(oid)
        do {
            try await Self.makeDirectory(directory)
        } catch {
            throw LocalStoreError.cannotCreateStorageDirectory(directory.path, String(describing: error))
        }
        return directory.appendingPathComponent(oid)
    }

    /// Whether the store holds object `oid` of `size` bytes
    /// (`ObjectExists`); the empty object always is.
    public func objectExists(_ oid: String, size: Int64) async throws -> Bool {
        guard size != 0 else { return true }
        let path = objectPathname(oid)
        try await Shell.authorize(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
        else { return false }
        return (attributes[.size] as? NSNumber)?.int64Value == size
    }

    private func localObjectDirectory(_ oid: String) -> URL {
        objectsDirectory
            .appendingPathComponent(String(oid.prefix(2)), isDirectory: true)
            .appendingPathComponent(String(oid.dropFirst(2).prefix(2)), isDirectory: true)
    }

    /// `tools.MkdirAll`, through the sandbox gate.
    static func makeDirectory(_ directory: URL) async throws {
        try await Shell.authorize(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
