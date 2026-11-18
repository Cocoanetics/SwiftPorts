import Foundation
import Crypto
import ShellKit

// Bringing objects in: a file in `tmp`, its SHA-256 checked against the OID
// it claims, then renamed into `objects/` (git-lfs `tools.TempFile`, the
// transfer adapters' verify, `tools.RenameFileCopyPermissions`).
extension LocalStore {

    /// A new, empty file in ``temporaryDirectory`` (`lfs.TempFile`).
    public func makeTemporaryFile() async throws -> URL {
        try await Self.makeDirectory(temporaryDirectory)
        let file = temporaryDirectory.appendingPathComponent(String(UInt32.random(in: .min ... .max)))
        try await Shell.authorize(file)
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        return file
    }

    /// Writes `data` to a file in ``temporaryDirectory`` and moves it into
    /// the store as object `oid` (see ``insert(temporaryFile:oid:)``).
    @discardableResult
    public func store(_ data: Data, oid: String) async throws -> URL {
        let file = try await makeTemporaryFile()
        try data.write(to: file)
        return try await insert(temporaryFile: file, oid: oid)
    }

    /// Moves `temporaryFile` into the store as object `oid`, once its
    /// SHA-256 is `oid`. A file whose hash differs stays where it is and
    /// throws ``LocalStoreError/unexpectedOID(expected:actual:written:)``.
    /// Another process having put the object there first is no failure.
    @discardableResult
    public func insert(temporaryFile: URL, oid: String) async throws -> URL {
        try await Shell.authorize(temporaryFile)
        let (actual, written) = try Self.sha256(of: temporaryFile)
        guard actual == oid else {
            throw LocalStoreError.unexpectedOID(expected: oid, actual: actual, written: written)
        }
        let destination = try await objectPath(oid)
        try await Shell.authorize(destination)
        do {
            try Self.renameCopyingPermissions(temporaryFile, to: destination)
        } catch where FileManager.default.fileExists(atPath: destination.path) {
            // Already downloaded, possibly by another git-lfs process.
        }
        return destination
    }

    /// The hex SHA-256 of the file at `url`, and how many bytes it has.
    static func sha256(of url: URL) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            count += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }

    /// `tools.RenameFileCopyPermissions`: gives `source` the mode of the
    /// file it replaces, if any, then renames it over `destination`.
    static func renameCopyingPermissions(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        if let permissions = try? manager.attributesOfItem(atPath: destination.path)[.posixPermissions] {
            do {
                try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: source.path)
            } catch {
                throw LocalStoreError.cannotSetFileMode(source.path, String(describing: error))
            }
        }
        do {
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: source)
            } else {
                try manager.moveItem(at: source, to: destination)
            }
        } catch {
            throw LocalStoreError.cannotReplace(destination.path, source.path, String(describing: error))
        }
    }
}
