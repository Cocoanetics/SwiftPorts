import Foundation
import GitKit
import ShellKit

public struct GitWorktreeInfo: Sendable, Equatable {
    public let name: String
    public let path: URL
    public let head: String?
    public let branch: String?
    public let isMain: Bool
    public let isLocked: Bool
    public let isPrunable: Bool

    public init(
        name: String,
        path: URL,
        head: String?,
        branch: String?,
        isMain: Bool,
        isLocked: Bool,
        isPrunable: Bool
    ) {
        self.name = name
        self.path = path
        self.head = head
        self.branch = branch
        self.isMain = isMain
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

// Sandbox-aware delegation onto the pure `Repository` worktree operations
// (`GitKit/Repository+Worktree.swift`).
extension GitClient {

    /// Add a linked worktree at `path`, checking out `branch`.
    public func worktreeAdd(path: URL, branch: String, force: Bool = false) async throws {
        try await Shell.authorize(path)
        try await withRepository {
            try $0.worktreeAdd(path: path, branch: branch, force: force)
        }
    }

    /// List worktrees known to this repository. GitKit's `worktreeList()`
    /// already mirrors `git worktree list`: primary worktree first,
    /// followed by linked worktrees.
    public func worktreeList() async throws -> [GitWorktreeInfo] {
        let entries = try await withRepository { try $0.worktreeList() }

        var result: [GitWorktreeInfo] = []
        result.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            let branch = try? await GitClient(
                workingDirectory: entry.path,
                credentials: credentials
            ).currentBranch()
            result.append(GitWorktreeInfo(
                name: entry.name,
                path: entry.path.standardizedFileURL,
                head: entry.head,
                branch: branch,
                isMain: index == 0,
                isLocked: entry.isLocked,
                isPrunable: entry.isPrunable))
        }

        return result
    }

    /// Remove a linked worktree by GitKit's administrative name.
    public func worktreeRemove(name: String, force: Bool = false) async throws {
        let linked = try await worktreeList()
            .first { !$0.isMain && $0.name == name }
        if let linked {
            try await Shell.authorize(linked.path)
        }
        try await withRepository {
            try $0.worktreeRemove(name: name, force: force)
        }
    }
}
