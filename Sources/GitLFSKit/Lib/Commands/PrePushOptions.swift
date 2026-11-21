import Foundation
import ShellKit
import SwiftGit

/// git-lfs 3.7.1 `commands/command_pre_push.go`, including its hook stdin format.
public struct PrePushOptions: Sendable {
    public var dryRun = false

    public init() {}

    public func run(
        _ arguments: [String], client: LFSClient, git: GitClient, terminal: Bool = false
    ) async throws -> LFSCommandResult {
        try await run(arguments, client: client, git: git, terminal: terminal) {
            let data = await Shell.current.stdin.readAllData()
            var updates: [LFSRefUpdate] = []
            for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
                let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                var fields = line.components(separatedBy: " ")
                while fields.count < 4 { fields.append("") }
                updates.append(LFSRefUpdate(localRef: fields[0], localOID: fields[1],
                                            remoteRef: fields[2], remoteOID: fields[3]))
            }
            return updates
        }
    }

    /// The hook as `git push` runs it in-process: `updates` are the lines git
    /// would write on its stdin.
    public func run(
        _ arguments: [String], updates: [LFSRefUpdate], client: LFSClient, git: GitClient, terminal: Bool = false
    ) async throws -> LFSCommandResult {
        try await run(arguments, client: client, git: git, terminal: terminal) { updates }
    }

    private func run(
        _ arguments: [String], client: LFSClient, git: GitClient, terminal: Bool,
        updates read: () async -> [LFSRefUpdate]
    ) async throws -> LFSCommandResult {
        do {
            guard let argument = arguments.first else {
                throw LFSFailure(
                    "This should be run through Git's pre-push hook.  Run `git lfs update` to install it.",
                    status: 1, stdout: true)
            }
            if LFSConfiguration.bool(Shell.env("GIT_LFS_SKIP_PUSH"), fallback: false) { return LFSCommandResult() }
            let config = client.finder.configuration
            let remote = config.remotes.first { name in
                let push = config.getAll("remote.\(name).pushurl")
                let urls = push.isEmpty ? config.getAll("remote.\(name).url") : push
                return urls == [argument]
            } ?? argument
            try await client.finder.validateRemote(remote, argument: argument)
            let updates = await read().filter { !LFSRefUpdate.isZero($0.localOID) }
            return try await client.pushUpdates(updates, remote: remote,
                                               dryRun: dryRun, terminal: terminal, git: git)
        } catch let failure as LFSFailure {
            return failure.result
        }
    }
}
