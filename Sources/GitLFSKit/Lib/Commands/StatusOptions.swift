import Foundation
import SwiftGit

/// git-lfs 3.7.1 `commands/command_status.go`. Rendering and the command
/// adapter build on ``scanIndex(_:client:repositoryRoot:)``.
struct StatusOptions: Sendable {
    /// `scanIndex`: the refreshed work-tree comparison is obtained before the
    /// cached one, then cached entries are drained first, so a record both
    /// diffs report is listed once, as staged.
    func scanIndex(
        _ ref: String = "HEAD", client: GitClient, repositoryRoot: URL
    ) async throws -> StatusIndex {
        let uncached = try await client.diffIndex(ref: ref, cached: false, refresh: true)
        let cached = try await client.diffIndex(ref: ref, cached: true)
        let compared = try await comparePointers(uncached, client: client, repositoryRoot: repositoryRoot)
        var seen = Set<[UInt8]>()
        let staged = Self.drain(cached, seen: &seen)
        let unstaged = Self.drain(compared, seen: &seen)
        return StatusIndex(staged: staged, unstaged: unstaged)
    }

    /// `drainScanner`: keeps the first record for each `keyFromEntry`.
    private static func drain(_ entries: [DiffIndexEntry], seen: inout Set<[UInt8]>) -> [DiffIndexEntry] {
        entries.filter { seen.insert(key($0)).inserted }
    }

    /// `keyFromEntry`: both ids and the destination, else the source, path.
    /// Paths compare by their bytes, as git prints them.
    private static func key(_ entry: DiffIndexEntry) -> [UInt8] {
        let name = entry.destinationPath.isEmpty ? entry.sourcePath : entry.destinationPath
        return Array("\(entry.oldOID):\(entry.newOID):".utf8) + Array(name.utf8)
    }
}
