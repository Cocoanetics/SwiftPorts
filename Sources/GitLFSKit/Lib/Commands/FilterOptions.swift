import Foundation
import ShellKit
import SwiftGit

/// git-lfs `lfs/attribute.go` FilterOptions and install/uninstall command behavior.
public struct FilterOptions: Sendable {
    public var local = false
    public var worktree = false
    public var system = false
    public var file = ""
    public var force = false
    public var skipSmudge = false
    public var skipRepo = false
    public var manual = false

    public init() {}

    public func install(_ client: SwiftGit.GitClient) async throws -> LFSCommandResult {
        do {
            try await validate(client)
            let config = try await FilterConfiguration.open(self, client: client)
            for (name, value, upgradeables) in properties {
                let key = "filter.lfs." + name
                let current = try config.value(key)
                if force || current.isEmpty || upgradeables.contains(current) {
                    try config.set(key, value)
                } else if current != value {
                    return LFSCommandResult(
                        stdout: "warning: the \(key.goQuoted) attribute should be \(value.goQuoted) "
                            + "but is \(current.goQuoted)\nRun `git lfs install --force` to reset Git configuration.\n",
                        status: 2)
                }
            }
            var result = LFSCommandResult()
            let inRepo = (try? await client.gitDir()) != nil
            if !skipRepo && (local || worktree || inRepo) {
                let repo = try await LFSRepository.open(client)
                try await updateAccess(client, result: &result)
                if force && manual {
                    result.fail("You cannot use --force and --manual options together")
                    return result
                }
                let hooks = Hook.loadHooks(directory: try await repo.hookDirectory(client))
                if manual {
                    let root = repo.workingDirectory?.path ?? ""
                    result.stdout += hooks.map { hook in
                        var directory = hook.directory.path
                        if directory.hasPrefix(root + "/") { directory = String(directory.dropFirst(root.count + 1)) }
                        return "Add the following to '\(directory)/\(hook.type)':\n\n\t"
                            + hook.contents.replacingOccurrences(of: "\n", with: "\n\t")
                    }.joined(separator: "\n\n") + "\n"
                } else {
                    do {
                        for hook in hooks { try await hook.install(force: force) }
                        result.stdout += "Updated Git hooks.\n"
                    } catch let error as LFSFailure {
                        result.stderr += error.result.stderr
                        result.fail("To resolve this, either:\n"
                            + "  1: run `git lfs update --manual` for instructions on how to merge hooks.\n"
                            + "  2: run `git lfs update --force` to overwrite your hook.")
                        return result
                    }
                }
            }
            result.stdout += "Git LFS initialized.\n"
            return result
        } catch let error as LFSFailure {
            return error.result
        }
    }

    public func uninstall(_ client: SwiftGit.GitClient) async throws -> LFSCommandResult {
        do {
            try await validate(client)
            var result = LFSCommandResult()
            let config = try await FilterConfiguration.open(self, client: client)
            if try await config.uninstall() == false {
                result.stdout += "warning: error running /usr/bin/git 'config' "
                    + "'\(local ? "--local" : worktree ? "--worktree" : system ? "--system" : "--global")' "
                    + "'--remove-section' 'filter.lfs': 'fatal: no such section: filter.lfs' 'exit status 128'\n"
            }
            let inRepo = (try? await client.gitDir()) != nil
            if !skipRepo && (local || worktree || inRepo) {
                let repo = try await LFSRepository.open(client)
                do {
                    for hook in Hook.loadHooks(directory: try await repo.hookDirectory(client)) {
                        try await hook.uninstall()
                    }
                } catch let error as LFSFailure {
                    result.stderr += error.result.stderr
                } catch {
                    result.stderr += "\(error.localizedDescription)\n"
                }
                result.stdout += "Hooks for this repository have been removed.\n"
            }
            if system { result.stdout += "System Git LFS configuration has been removed.\n" }
            else if !local && !worktree { result.stdout += "Global Git LFS configuration has been removed.\n" }
            return result
        } catch let error as LFSFailure {
            return error.result
        }
    }

    private func validate(_ client: SwiftGit.GitClient) async throws {
        // Upstream checks repository presence before conflicting destination flags.
        if local || worktree { _ = try await LFSRepository.open(client) }
        if [local, worktree, system, !file.isEmpty].filter({ $0 }).count > 1 {
            throw LFSFailure("Only one of the --local, --system, --worktree, and --file options can be specified.")
        }
    }

    private var properties: [(String, String, [String])] {
        [
            ("clean", "git-lfs clean -- %f", skipSmudge ? ["git-lfs clean -- %f"] : ["git-lfs clean %f"]),
            ("smudge", skipSmudge ? "git-lfs smudge --skip -- %f" : "git-lfs smudge -- %f",
             ["git-lfs smudge %f", "git-lfs smudge --skip %f",
              skipSmudge ? "git-lfs smudge -- %f" : "git-lfs smudge --skip -- %f"]),
            ("process", "git-lfs filter-process" + (skipSmudge ? " --skip" : ""),
             ["git-lfs filter", "git-lfs filter --skip",
              skipSmudge ? "git-lfs filter-process" : "git-lfs filter-process --skip"]),
            ("required", "true", [])
        ]
    }

    private func updateAccess(_ client: SwiftGit.GitClient, result: inout LFSCommandResult) async throws {
        for (key, value) in try await client.configList()
        where key.hasPrefix("lfs.") && key.hasSuffix(".access") {
            let name = String(key.dropFirst(4).dropLast(7))
            if value == "private" {
                try await client.configSet(key, "basic")
                result.stdout += "Updated \(name) access from private to basic.\n"
            } else if value != "basic" {
                try await client.configUnset(key)
                result.stdout += "Removed invalid \(name) access of \(value).\n"
            }
        }
    }
}
