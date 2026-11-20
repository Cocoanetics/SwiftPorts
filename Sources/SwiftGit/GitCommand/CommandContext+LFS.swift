import Foundation
import GitLFSKit
import ShellKit
import SwiftGit

extension CommandContext {
    /// An LFS client rooted like ``gitClient(quiet:)``. Credentials are
    /// ``envCredentialProvider()``, the same callback a `GitClient` gets,
    /// so LFS never shells out to `git credential`.
    static func lfsClient(quiet: Bool = false) async -> LFSClient {
        await LFSClient(git: gitClient(quiet: quiet), credentials: envCredentialProvider())
    }

    /// The repository selected for `git lfs env`. Git LFS asks git for its
    /// repository paths after git has applied `GIT_DIR` / `GIT_WORK_TREE`, so
    /// an invocation outside the work tree must not fall back to cwd.
    static func lfsEnvironmentGitClient() -> SwiftGit.GitClient {
        let environment = Shell.current.environment
        let gitDirectory = environment["GIT_DIR"].flatMap(environmentPath)
        let workTree = environment["GIT_WORK_TREE"].flatMap(environmentPath)
        let directory: URL
        if let gitDirectory, let workTree,
           gitDirectory.standardizedFileURL == workTree.appendingPathComponent(".git").standardizedFileURL {
            // Opening the ordinary work tree preserves libgit2's non-bare
            // repository view while still selecting the GIT_DIR it contains.
            directory = workTree
        } else {
            directory = gitDirectory ?? workTree ?? currentDirectory
        }
        return SwiftGit.GitClient(workingDirectory: directory, credentials: envCredentialProvider())
    }

    private static func environmentPath(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, relativeTo: currentDirectory).standardizedFileURL
    }
}
