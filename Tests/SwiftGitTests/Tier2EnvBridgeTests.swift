// Demonstrates the env→option bridge in action: without an active
// `Sandbox`, libgit2 reads the host's `~/.gitconfig` and surfaces the
// real user's name + email through `git_signature_default`. With an
// active `Sandbox` whose `environment()` returns a sandboxed `HOME`,
// the bridge applies `SET_SEARCH_PATH(GLOBAL, sandboxHOME)` +
// `SET_HOMEDIR` before opening the repo, so libgit2's config-search
// finds nothing — host gitconfig becomes invisible.
//
// macOS-only: Linux CI runners typically have an empty
// `~/.gitconfig`, so the leak arm has nothing to demonstrate.
// Windows is gated out for the same reason as the symlink-escape
// test — paths and CRLF complications.
//
// The suite is `.serialized`, and the leak arm restores libgit2's
// defaults before reading — the option block is process-global, and
// the default-secure test (deliberately) leaves it pinned to a
// sandbox home.
#if os(macOS)
import Foundation
import Testing
import CGitKit
import ShellKit
@testable import SwiftGit

@Suite("Tier-2 env→option bridge",
       .serialized)
struct Tier2EnvBridgeTests {

    /// Regression for chatgpt-codex-connector PR #19 review comment:
    /// when the sandbox env doesn't include `HOME` (the default for
    /// `Sandbox.rooted(at:)`, whose default env is just `["PWD": …]`),
    /// the bridge MUST still redirect libgit2's config search away
    /// from the host `~/.gitconfig`. Otherwise the very common
    /// rooted-sandbox case silently leaks host data.
    ///
    /// This test exercises the default-secure path: a Sandbox with
    /// no env override. Skipped silently when the host has no
    /// `user.name` configured (CI runners).
    @Test func bridgeIsDefaultSecureWhenEnvHasNoHOME() async throws {
        let repoDir = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repoDir) }

        let hostName = readGlobalConfig("user.name")
        guard let hostName, !hostName.isEmpty else { return }

        // No environment override — Shell defaults give an empty
        // env, which is exactly what this test wants (HOME unset
        // forces libgit2's default-secure fallback to the sandbox's
        // own homeDirectory).
        let sandbox = Sandbox.rooted(at: repoDir)
        let shell = Shell(environment: Environment(), sandbox: sandbox)
        try await shell.withCurrent {
            let client = SwiftGit.GitClient(workingDirectory: repoDir)
            _ = try await client.localBranches()
        }

        // After the sandboxed call, libgit2's GLOBAL search path was
        // set to `sandbox.homeDirectory` (the bridge's fallback).
        // Confirm by reading user.name at GLOBAL — should be empty.
        let leaked = readUserNameAtGlobalLevel(repoAt: repoDir)
        #expect(leaked == nil || leaked?.isEmpty == true,
                Comment(rawValue:
                    "Default-secure isolation broken: GLOBAL config still " +
                    "contains user.name=\(leaked ?? "nil") (expected nothing). " +
                    "Host gitconfig leaks into Sandbox.rooted(at:) by default."))
    }

    @Test func bridgeRedirectsConfigSearchToSandboxHome() async throws {
        // Set up a fresh repo on disk that we can open via libgit2.
        let repoDir = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repoDir) }

        // ARM 1 (no sandbox): demonstrate the leak. Skip silently when
        // the host has no `user.name` / `user.email` configured (CI).
        let hostName = readGlobalConfig("user.name")
        let hostEmail = readGlobalConfig("user.email")
        guard let hostName, !hostName.isEmpty,
              let hostEmail, !hostEmail.isEmpty else {
            return
        }

        // libgit2's option block is process-global, and the preceding
        // `.serialized` test deliberately leaves it pinned to a sandbox
        // home (the default-secure guarantee it proves). Restore
        // libgit2's defaults so this negative control observes the
        // HOST config search path again.
        try Libgit2Sandboxing.shared.runIsolated(nil) {}

        let leaked = readUserNameAtGlobalLevel(repoAt: repoDir)
        #expect(leaked == hostName,
                "expected libgit2 to leak \(hostName) without Layer A; got \(leaked ?? "nil")")

        // ARM 2 (with sandbox): apply the bridge by activating a
        // `Sandbox` whose `environment()` returns a HOME pointing at
        // an empty scratch dir. Layer A's runIsolated path is the
        // hook we've inserted at the top of every withRepository
        // call, so any GitClient operation under this Sandbox.current
        // gets the option-block applied. We exercise it by opening a
        // GitClient and reading localBranches (which routes through
        // withRepository).
        let scratchHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tier2-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratchHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchHome) }

        let sandbox = Sandbox.rooted(at: repoDir)
        var env = Environment()
        env.variables = ["HOME": scratchHome.path]
        let shell = Shell(environment: env, sandbox: sandbox)

        try await shell.withCurrent {
            // Drive a GitClient operation so the tier-2 hook runs
            // (Libgit2Sandboxing.runIsolated → setSearchPath(GLOBAL,
            // scratchHome) + setHomedir(scratchHome)).
            let client = SwiftGit.GitClient(workingDirectory: repoDir)
            _ = try await client.localBranches()
        }

        // After the sandbox-activated call, options have been
        // applied. Read the GLOBAL config now and confirm the leak
        // is closed. (The actor releases the lock at the end of
        // runIsolated, so the option block remains pointed at
        // scratchHome until the next runIsolated reapplies. That's
        // fine for this test.)
        let blocked = readUserNameAtGlobalLevel(repoAt: repoDir)
        #expect(blocked == nil || blocked?.isEmpty == true,
                "expected GLOBAL config to be empty under sandbox; got \(blocked ?? "nil")")
    }

    // MARK: - Helpers

    private func makeTempRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tier2-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        Libgit2.ensureInitialized()
        var repo: OpaquePointer?
        var opts = git_repository_init_options()
        _ = git_repository_init_init_options(
            &opts, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
        opts.flags = UInt32(GIT_REPOSITORY_INIT_MKDIR.rawValue)
            | UInt32(GIT_REPOSITORY_INIT_MKPATH.rawValue)
        _ = git_repository_init_ext(&repo, dir.path, &opts)
        git_repository_free(repo)
        return dir
    }

    private func readUserNameAtGlobalLevel(repoAt dir: URL) -> String? {
        Libgit2.ensureInitialized()
        var repo: OpaquePointer?
        guard git_repository_open_ext(&repo, dir.path, 0, nil) == 0
        else { return nil }
        defer { git_repository_free(repo) }
        var cfg: OpaquePointer?
        guard git_repository_config(&cfg, repo) == 0 else { return nil }
        defer { git_config_free(cfg) }
        var leveled: OpaquePointer?
        guard git_config_open_level(&leveled, cfg, GIT_CONFIG_LEVEL_GLOBAL) == 0
        else { return nil }
        defer { git_config_free(leveled) }
        var entry: UnsafeMutablePointer<git_config_entry>?
        guard git_config_get_entry(&entry, leveled, "user.name") == 0
        else { return nil }
        defer { git_config_entry_free(entry) }
        guard let valuePtr = entry?.pointee.value else { return nil }
        return String(cString: valuePtr)
    }

    private func readGlobalConfig(_ key: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "config", "--global", key]
        let out = Pipe(); p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }
}
#endif
