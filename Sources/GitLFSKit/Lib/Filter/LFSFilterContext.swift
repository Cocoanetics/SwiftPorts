import Foundation
import ForgeKit
import ShellKit
import SwiftGit

/// Metadata captured while the outer git operation's callback lease is active.
struct LFSFilterContext: Sendable {
    let client: LFSClient
    let store: LocalStore
    let required: Bool
    let skipSmudge: Bool
    let shell: Shell
    let remotes: LFSFilterRemotes
    var processCommand: String?

    static func command(_ git: SwiftGit.GitClient, direction: GitFilterDirection) async throws -> String? {
        // convert.c gives process presence precedence, including an empty value.
        if let process = try await git.configGet("filter.lfs.process") {
            return process.isEmpty ? nil : process
        }
        let key = direction == .clean ? "filter.lfs.clean" : "filter.lfs.smudge"
        guard let command = try await git.configGet(key), !command.isEmpty else { return nil }
        return command
    }

    static func load(
        _ git: SwiftGit.GitClient, direction: GitFilterDirection, remotes: LFSFilterRemotes
    ) async throws -> LFSFilterContext? {
        let required = try await git.configBool("filter.lfs.required") == true
        guard let command = try await command(git, direction: direction) else {
            if required {
                // Git's streamable checkout bypasses a driver only when all commands are absent.
                // Any configured command, even empty or clean-only, selects in-core conversion.
                let process = try await git.configGet("filter.lfs.process")
                let smudge = try await git.configGet("filter.lfs.smudge")
                let clean = try await git.configGet("filter.lfs.clean")
                if direction == .clean || process != nil || smudge != nil || clean != nil { throw LFSClientError("") }
            }
            return nil
        }
        do {
            return try await LFSFilterContext(
                client: LFSClient(git: git, credentials: git.credentials), store: LocalStore.open(git),
                required: required,
                skipSmudge: command.split(whereSeparator: \.isWhitespace).contains("--skip")
                    || LFSConfiguration.bool(Shell.env("GIT_LFS_SKIP_SMUDGE"), fallback: false),
                shell: Shell.current, remotes: remotes,
                processCommand: try await git.configGet("filter.lfs.process"))
        } catch {
            guard !required else { throw error }
            return nil
        }
    }

    func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        try BlockingBridge.runBlocking { try await shell.withCurrent(body) }
    }

    var configuration: LFSConfiguration { client.finder.configuration }

    /// git-lfs GitFilter.RemoteRef uses the push remote's default ref mapping.
    var refName: String {
        let finder = client.finder
        guard let branch = finder.branch else { return "HEAD" }
        let mode = configuration.get("push.default") ?? ""
        if ["upstream", "tracking"].contains(mode)
            || (["", "simple"].contains(mode)
                && configuration.get("branch.\(branch).remote") == finder.uploadRemote()) {
            return configuration.get("branch.\(branch).merge") ?? "refs/heads/\(branch)"
        }
        return "refs/heads/\(branch)"
    }
}
