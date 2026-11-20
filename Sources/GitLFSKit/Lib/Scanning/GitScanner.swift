import Foundation
import SwiftGit

/// Ordered Git LFS pointer scans, using the sandbox-aware, in-process client.
public struct GitScanner: Sendable {
    private let client: GitClient
    private let filter: FilepathFilter

    public init(client: GitClient, filter: FilepathFilter = FilepathFilter()) {
        self.client = client
        self.filter = filter
    }

    /// Depth-first Git tree order, retaining every path even for shared blobs.
    public func scanTree(_ ref: String = "HEAD") async throws -> [WrappedPointer] {
        var result: [WrappedPointer] = []
        try await walkTree(ref) { oid, name in
            if let pointer = try await readPointer(oid, name: name) { result.append(pointer) }
        }
        return result
    }

    /// Cached diff destinations first, then the ref tree. Only destinations
    /// emitted as pointers override tree paths; staged deletions remain in
    /// the ref tree. `workingDirectory` is reserved for the status consumer.
    public func scanIndex(
        ref: String = "HEAD", workingDirectory: URL? = nil
    ) async throws -> [WrappedPointer] {
        let entries = try await client.diffIndex(ref: ref, cached: true)
        var result: [WrappedPointer] = []
        var emitted = Set<String>()
        for entry in entries {
            // Absent/unmerged sides have mode zero; gitlinks are not blobs.
            guard entry.newMode != 0, entry.newMode != 0o160000,
                  let pointer = try await readPointer(
                    entry.newOID, name: entry.destinationPath,
                    sourceName: entry.sourcePath, status: String(entry.status)) else { continue }
            result.append(pointer)
            emitted.insert(entry.destinationPath)
        }
        // diffIndex already validated the ref and only accepts a missing
        // HEAD when it is unborn. Other repository/revision errors propagate.
        if ref == "HEAD", try await client.canResolveRef(ref) == false { return result }
        try await walkTree(ref) { oid, name in
            guard !emitted.contains(name) else { return }
            if let pointer = try await readPointer(oid, name: name) { result.append(pointer) }
        }
        return result
    }

    /// Unique Git blobs in rev-list order, subtracting all objects reachable
    /// from excluded commits. A filtered path still consumes its blob OID.
    public func scanRefs(include: [String], exclude: [String] = []) async throws -> [WrappedPointer] {
        var seen = Set<String>()
        if !exclude.isEmpty {
            for commit in try await client.revList(starts: exclude) {
                try await walkTree(commit) { oid, _ in seen.insert(oid) }
            }
        }
        var result: [WrappedPointer] = []
        for commit in try await client.revList(starts: include, excludes: exclude) {
            try await walkTree(commit) { oid, name in
                guard seen.insert(oid).inserted else { return }
                if let pointer = try await readPointer(oid, name: name) { result.append(pointer) }
            }
        }
        return result
    }

    /// One history walk from all refs/ tips and HEAD (including detached HEAD).
    public func scanAll() async throws -> [WrappedPointer] {
        var starts = try await client.references(matching: nil).map(\.targetSHA)
        // revList omits an unborn HEAD, while propagating a corrupt or
        // missing object. Resolve it as part of the same walk as all refs.
        starts.append("HEAD")
        return try await scanRefs(include: starts)
    }

    private func walkTree(
        _ ref: String, prefix: String = "",
        visit: (String, String) async throws -> Void
    ) async throws {
        for entry in try await client.lsTree(treeish: ref, recursive: false) {
            try Task.checkCancellation()
            let name = prefix + entry.path
            switch entry.kind {
            case .tree: try await walkTree(entry.sha, prefix: name + "/", visit: visit)
            case .blob: try await visit(entry.sha, name)
            case .commit, .tag: break
            }
        }
    }

    private func readPointer(
        _ oid: String, name: String, sourceName: String = "", status: String = ""
    ) async throws -> WrappedPointer? {
        guard filter.allows(name) else { return nil }
        let metadata = try await client.objectMetadata(of: oid)
        guard metadata.kind == .blob, metadata.size < Pointer.blobSizeCutoff else { return nil }
        let data = try await client.catFileBlob(oid)
        do {
            return WrappedPointer(pointer: try Pointer.decode(data), oid: metadata.sha,
                                  name: name, sourceName: sourceName, status: status)
        } catch is PointerError {
            return nil
        }
    }
}
