import Foundation
import ShellKit
import SwiftGit

/// The setupRepository/setupWorkingCopy checks shared by the upstream commands.
struct LFSRepository {
    let gitDirectory: URL
    let commonDirectory: URL
    let workingDirectory: URL?

    static func open(
        _ client: SwiftGit.GitClient, workTree: Bool = false, verifyFormat: Bool = true
    ) async throws -> LFSRepository {
        guard let directory = try? await client.gitDir(),
              let common = try await client.commonDir() else {
            throw LFSFailure("Not in a Git repository.", status: 128, stdout: true)
        }
        let root = try await client.toplevel()
        if workTree && root == nil {
            throw LFSFailure("This operation must be run in a work tree.", status: 128, stdout: true)
        }
        if verifyFormat {
            let version = try await client.configGet("lfs.repositoryformatversion", scope: .local)
            if version == nil || version == "" {
                try await client.configSet("lfs.repositoryformatversion", "0")
            } else if version != "0" {
                throw LFSFailure("Unknown repository format version: \(version ?? "")", status: 128, stdout: true)
            }
        }
        return LFSRepository(gitDirectory: URL(fileURLWithPath: directory),
                             commonDirectory: URL(fileURLWithPath: common),
                             workingDirectory: root.map { URL(fileURLWithPath: $0) })
    }

    func hookDirectory(_ client: SwiftGit.GitClient) async throws -> URL {
        if let path = try await client.configGet("core.hooksPath") {
            let expanded: String
            if path == "~" || path.hasPrefix("~/") {
                expanded = (Shell.env("HOME") ?? "") + path.dropFirst()
            } else {
                expanded = path
            }
            return URL(fileURLWithPath: expanded, relativeTo: workingDirectory ?? Shell.currentDirectory)
        }
        return commonDirectory.appendingPathComponent("hooks")
    }
}
