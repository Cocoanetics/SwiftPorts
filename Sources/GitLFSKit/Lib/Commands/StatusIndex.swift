import SwiftGit

/// The `staged` and `unstaged` lists of git-lfs 3.7.1 `commands/command_status.go`
/// `scanIndex`, in scan order. Ordinary Git files stay in both lists.
struct StatusIndex: Sendable, Equatable {
    let staged: [DiffIndexEntry]
    let unstaged: [DiffIndexEntry]
}
