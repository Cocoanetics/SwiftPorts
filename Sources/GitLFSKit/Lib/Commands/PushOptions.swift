import Foundation
import ShellKit
import SwiftGit

/// git-lfs 3.7.1 `commands/command_push.go`. Stdin contains one ref or OID per line.
public struct PushOptions: Sendable {
    public var all = false
    public var dryRun = false
    public var objectID = false
    public var stdin = false

    public init() {}

    public func run(
        _ arguments: [String], client: LFSClient, git: GitClient, terminal: Bool = false
    ) async throws -> LFSCommandResult {
        do {
            guard let remote = arguments.first else {
                throw LFSFailure("Specify a remote and a remote branch name (`git lfs push origin main`)",
                                 status: 1, stdout: true)
            }
            try await client.finder.validateRemote(remote)
            if stdin && arguments.count > 1 {
                throw LFSFailure("Further command line arguments are ignored with --stdin", status: 1, stdout: true)
            }
            let names: [String]
            if stdin {
                let data = await Shell.current.stdin.readAllData()
                names = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
                    .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }.filter { !$0.isEmpty }
            } else {
                names = Array(arguments.dropFirst())
            }
            if objectID {
                if !stdin && names.isEmpty {
                    throw LFSFailure("At least one object ID must be supplied with --object-id",
                                     status: 1, stdout: true)
                }
                return try await client.pushObjectIDs(names, remote: remote, dryRun: dryRun,
                                                      terminal: terminal, git: git)
            }
            if !stdin && !all && names.isEmpty {
                throw LFSFailure("At least one ref must be supplied without --all", status: 1, stdout: true)
            }
            let references = try await git.references(matching: nil)
            // `git show-ref` exits 1 in an empty repository, before lfsPushRefs selects local refs.
            if references.isEmpty { throw LFSFailure("exit status 1\nError getting local refs.") }
            let local = references.filter {
                $0.name.hasPrefix("refs/heads/") || $0.name.hasPrefix("refs/tags/")
            }
            let refs = all && names.isEmpty ? local.map(\.name) : names
            var updates: [LFSRefUpdate] = []
            for name in refs {
                guard let ref = try? await client.commandRef(name, git: git) else {
                    throw LFSFailure("Invalid ref argument: \(name)\nError getting local refs.")
                }
                let oid = try await git.resolveOID(ref)
                let branch = LFSClient.refName(ref)
                let remoteOID = (try? await git.resolveOID("refs/remotes/\(remote)/\(branch)"))
                    ?? String(repeating: "0", count: 40)
                updates.append(LFSRefUpdate(localRef: ref, localOID: oid, remoteRef: "", remoteOID: remoteOID))
            }
            return try await client.pushUpdates(updates, remote: remote, all: all,
                                               dryRun: dryRun, terminal: terminal, git: git)
        } catch let failure as LFSFailure {
            return failure.result
        }
    }
}
