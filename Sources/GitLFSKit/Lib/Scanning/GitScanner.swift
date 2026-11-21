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
    /// from the excluded refs. A filtered path still consumes its blob OID.
    /// As with `rev-list --objects`, a ref may name (or tag) a tree or blob
    /// as well as a commit; those roots are walked before commit history.
    public func scanRefs(include: [String], exclude: [String] = []) async throws -> [WrappedPointer] {
        let included = try await classify(include)
        let excluded = try await classify(exclude)
        var seen = try await reachable(from: excluded)
        var result: [WrappedPointer] = []
        try await scan(included, seen: &seen, into: &result)
        if !included.commits.isEmpty {
            result += try await scanHistory(include: included.commits, exclude: excluded.commits, seen: &seen)
        }
        return result
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

        let roots = try await classify(targets)
        var seen = Set<String>()
        var result: [WrappedPointer] = []
        try await scan(roots, seen: &seen, into: &result)
        if !roots.commits.isEmpty {
            result += try await scanHistory(include: roots.commits, exclude: [], seen: &seen)
        }
        return result
    }

    /// Peels each target (`^{}` through every tag) and sorts it by kind.
    private func classify(_ targets: [String]) async throws -> GitScanRoots {
        var roots = GitScanRoots()
        var seenTargets = Set<String>()
        for target in targets {
            // revList treats an unborn HEAD as empty and still throws for a
            // missing or corrupt one; there is no object to classify.
            if target == "HEAD", try await !client.canResolveRef(target) {
                roots.commits.append(target)
                continue
            }
            var metadata = try await client.objectMetadata(of: target)
            if metadata.kind == .tag {
                metadata = try await client.objectMetadata(of: target + "^{}")
            }
            guard seenTargets.insert(metadata.sha).inserted else { continue }
            switch metadata.kind {
            case .commit:
                roots.commits.append(metadata.sha)
            case .tree:
                roots.roots.append(.tree(metadata.sha))
            case .blob:
                roots.roots.append(.blob(metadata.sha))
            case .tag:
                break // `^{}` above peels through every tag.
            }
        }
        return roots
    }

    /// The pointers under tree and blob roots not yet `seen`.
    private func scan(
        _ roots: GitScanRoots, seen: inout Set<String>, into result: inout [WrappedPointer]
    ) async throws {
        for root in roots.roots {
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
    }

    /// Every object reachable from excluded roots, trees and blobs included.
    private func reachable(from roots: GitScanRoots) async throws -> Set<String> {
        var seen = Set<String>()
        for root in roots.roots {
            switch root {
            case .tree(let oid): try await walkTree(oid) { oid, _ in seen.insert(oid) }
            case .blob(let oid): seen.insert(oid)
            }
        }
        if !roots.commits.isEmpty {
            for commit in try await client.revList(starts: roots.commits) {
                try await walkTree(commit) { oid, _ in seen.insert(oid) }
            }
        }
        return seen
    }

    /// `rev-list --objects` over commits: the trees of `include`'s history
    /// not reached from `exclude`, skipping objects already `seen`.
    private func scanHistory(
        include: [String], exclude: [String], seen: inout Set<String>
    ) async throws -> [WrappedPointer] {
        var result: [WrappedPointer] = []
        for commit in try await client.revList(starts: include, excludes: exclude) {
            try await walkTree(commit) { oid, name in
                guard seen.insert(oid).inserted else { return }
                if let pointer = try await readPointer(oid, name: name) { result.append(pointer) }
            }
        }
        return result
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
        guard let pointer = try await PointerScanner(client: client).readPointer(oid) else { return nil }
        return WrappedPointer(pointer: pointer, oid: oid,
                              name: name, sourceName: sourceName, status: status)
    }
}
