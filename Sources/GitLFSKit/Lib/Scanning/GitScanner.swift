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
        var emitted = Set<[UInt8]>()
        for entry in entries {
            // Absent/unmerged sides have mode zero; gitlinks are not blobs.
            guard entry.newMode != 0, entry.newMode != 0o160000,
                  let pointer = try await readPointer(
                    entry.newOID, name: entry.destinationPath,
                    sourceName: entry.sourcePath, status: String(entry.status)) else { continue }
            result.append(pointer)
            emitted.insert(Array(entry.destinationPath.utf8))
        }
        // diffIndex already validated the ref and only accepts a missing
        // HEAD when it is unborn. Other repository/revision errors propagate.
        if ref == "HEAD", try await client.canResolveRef(ref) == false { return result }
        try await walkTree(ref) { oid, name in
            guard !emitted.contains(Array(name.utf8)) else { return }
            if let pointer = try await readPointer(oid, name: name) { result.append(pointer) }
        }
        return result
    }

    /// Unique Git blobs in rev-list order, subtracting all objects reachable
    /// from excluded commits. A filtered path still consumes its blob OID.
    public func scanRefs(include: [String], exclude: [String] = []) async throws -> [WrappedPointer] {
        try await scanRefs(include: include, exclude: exclude, seen: []).pointers
    }

    /// One history walk from all refs/ tips and HEAD (including detached HEAD).
    /// Direct tree and blob refs are walked first, in ref order, as
    /// `git rev-list --objects --all` visits non-commit roots before commit
    /// trees. All commit roots then share one history walk.
    public func scanAll() async throws -> [WrappedPointer] {
        var targets = try await client.references(matching: nil).map(\.targetSHA)
        if try await client.canResolveRef("HEAD") {
            targets.append("HEAD")
        } else {
            // `canResolveRef` deliberately turns every lookup failure into
            // false. revList distinguishes an unborn HEAD (empty) from a
            // corrupt or missing object (throw), preserving scanner errors.
            _ = try await client.revList(starts: ["HEAD"])
        }

        enum Root {
            case tree(String)
            case blob(String)
        }
        var roots: [Root] = []
        var history: [String] = []
        var seenTargets = Set<String>()
        for target in targets {
            var metadata = try await client.objectMetadata(of: target)
            if metadata.kind == .tag {
                metadata = try await client.objectMetadata(of: target + "^{}")
            }
            guard seenTargets.insert(metadata.sha).inserted else { continue }
            switch metadata.kind {
            case .commit:
                history.append(metadata.sha)
            case .tree:
                roots.append(.tree(metadata.sha))
            case .blob:
                roots.append(.blob(metadata.sha))
            case .tag:
                break // `^{}` above peels through every tag.
            }
        }

        var seen = Set<String>()
        var result: [WrappedPointer] = []
        for root in roots {
            switch root {
            case .tree(let oid):
                try await walkTree(oid) { oid, name in
                    guard seen.insert(oid).inserted else { return }
                    if let pointer = try await readPointer(oid, name: name) { result.append(pointer) }
                }
            case .blob(let oid):
                guard seen.insert(oid).inserted else { continue }
                if let pointer = try await readPointer(oid, name: "") { result.append(pointer) }
            }
        }
        if !history.isEmpty {
            let scan = try await scanRefs(include: history, exclude: [], seen: seen)
            result += scan.pointers
        }
        return result
    }

    private func scanRefs(
        include: [String], exclude: [String], seen initialSeen: Set<String>
    ) async throws -> (pointers: [WrappedPointer], seen: Set<String>) {
        var seen = initialSeen
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
        return (result, seen)
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
        guard let size = try await client.blobSize(ofOID: oid),
              size < Pointer.blobSizeCutoff else { return nil }
        let data = try await client.catFileBlob(oid)
        do {
            return WrappedPointer(pointer: try Pointer.decode(data), oid: oid,
                                  name: name, sourceName: sourceName, status: status)
        } catch is PointerError {
            return nil
        }
    }
}
