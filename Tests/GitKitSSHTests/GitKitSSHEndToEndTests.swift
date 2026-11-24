// End-to-end coverage for issue #113: clone, fetch and push through the
// full stack — GitKit's Repository operations, carried over
// GitKitSSHTransportProvider, over SSHKit's exec channel, over a real,
// throwaway OpenSSH `sshd`. Skips (rather than fails) when no system
// `sshd`/`ssh-keygen` is available, matching `SSHClientThrowawaySSHDTests`.
//
// Every test registers/unregisters GitKit's process-wide
// `GitSSHTransport` itself, so the suite runs serialized to avoid two
// tests racing on that single global slot.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import GitKit
import GitKitSSH
import ForgeKit
import ShellKit
import SSHTestSupport

@Suite("GitKitSSH (throwaway sshd)", .serialized)
struct GitKitSSHEndToEndTests {

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    private func tmp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out; process.standardError = err
        try process.run()
        ThrowawaySSHD.waitForExit(process, timeout: 60)
        let outStr = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        if process.terminationStatus != 0 {
            let errStr = String(decoding: (try? err.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            throw Failure("git \(args.joined(separator: " ")) failed: \(errStr)")
        }
        return outStr
    }

    /// A bare repo with one commit, servable by `git-upload-pack`.
    private func makeBareSource() throws -> URL {
        let work = tmp("GitKitSSHSourceWork")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: work)
        try runGit(["config", "user.email", "test@example.com"], in: work)
        try runGit(["config", "user.name", "Test"], in: work)
        try Data("hi\n".utf8).write(to: work.appendingPathComponent("file.txt"))
        try runGit(["add", "."], in: work)
        try runGit(["commit", "-q", "-m", "init"], in: work)

        let bare = tmp("GitKitSSHSource")
        try runGit(["clone", "-q", "--bare", work.path, bare.path], in: work)
        return bare
    }

    /// An empty bare repo, servable by `git-receive-pack`.
    private func makeBareDestination() throws -> URL {
        let bare = tmp("GitKitSSHDestination")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try runGit(["init", "-q", "--bare", "-b", "main"], in: bare)
        return bare
    }

    /// A non-bare repo with one commit on `main`, ready to push from.
    private func makeWorkRepo() throws -> URL {
        let work = tmp("GitKitSSHPushWork")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: work)
        try runGit(["config", "user.email", "test@example.com"], in: work)
        try runGit(["config", "user.name", "Test"], in: work)
        try Data("hi\n".utf8).write(to: work.appendingPathComponent("file.txt"))
        try runGit(["add", "."], in: work)
        try runGit(["commit", "-q", "-m", "init"], in: work)
        return work
    }

    /// Writes an `ssh_config` with one `Host` alias resolving to the throwaway sshd, and returns
    /// its path alongside the alias to put in a git `ssh://` URL.
    private func writeSSHConfig(
        _ sshd: ThrowawaySSHD, identityPath: String, knownHostsPath: String
    ) throws -> (configPath: String, alias: String) {
        let alias = "gitkitssh-test-host"
        let configPath = tmp("GitKitSSHConfig").appendingPathComponent("ssh_config").path
        try sshd.writeSSHConfig(
            to: configPath, alias: alias, identityPath: identityPath, knownHostsPath: knownHostsPath)
        return (configPath, alias)
    }

    @Test("clone, fetch and push carry real bytes over the registered SSHKit transport")
    func cloneFetchAndPush() async throws {
        let identityPath = try ThrowawaySSHIdentity.generate(in: tmp("GitKitSSHIdentity")).privateKeyPath
        guard let sshd = try await ThrowawaySSHD.start(authorizingPublicKeyPath: identityPath + ".pub") else {
            return
        }
        defer { sshd.stop() }

        let knownHostsPath = tmp("GitKitSSHKnownHosts").path
        try sshd.knownHostsLine()
            .write(toFile: knownHostsPath, atomically: true, encoding: .utf8)

        let (configPath, alias) = try writeSSHConfig(sshd, identityPath: identityPath, knownHostsPath: knownHostsPath)

        try GitSSHTransport.register(GitKitSSHTransportProvider(sshConfigPath: configPath))
        defer { GitSSHTransport.unregister() }

        // Clone.
        let source = try makeBareSource()
        let cloneDest = tmp("GitKitSSHCloneDest")
        let cloned = try Repository.clone(from: URL(string: "ssh://\(alias)\(source.path)")!, to: cloneDest)
        #expect(FileManager.default.fileExists(atPath: cloneDest.appendingPathComponent("file.txt").path))
        _ = cloned

        // Fetch.
        let fetchDest = tmp("GitKitSSHFetchDest")
        let fetchRepo = try Repository.initialize(at: fetchDest, initialBranch: "main")
        try fetchRepo.addRemote(name: "origin", url: URL(string: "ssh://\(alias)\(source.path)")!)
        try fetchRepo.fetch(remote: "origin", refspec: "+refs/heads/*:refs/remotes/origin/*", progress: { _ in })
        try runGit(["rev-parse", "refs/remotes/origin/main"], in: fetchDest)

        // Push.
        let destBare = try makeBareDestination()
        let work = try makeWorkRepo()
        let pushRepo = try Repository.open(at: work)
        try pushRepo.addRemote(name: "origin", url: URL(string: "ssh://\(alias)\(destBare.path)")!)
        try pushRepo.push(remote: "origin", refspec: "main", setUpstream: false)
        let localSHA = try runGit(["rev-parse", "HEAD"], in: work)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteSHA = try runGit(["rev-parse", "main"], in: destBare)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(localSHA == remoteSHA)
    }

    /// Issue #122: the transport's connection goes through the sandbox of the shell the git
    /// operation runs in — which also proves `BlockingBridge`'s task carries that shell along.
    /// No sshd needed: a sandbox that allows no hosts must refuse before anything is dialled
    /// (nothing listens on port 9, so a dial would fail with a different error).
    @Test("an SSH fetch is refused by the bound shell's sandbox before dialling")
    func fetchIsDeniedByTheBoundSandbox() async throws {
        let root = tmp("GitKitSSHSandboxRoot")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        let shell = Shell(environment: Environment(), sandbox: Sandbox.rooted(at: root))

        // The default `~/.ssh/config` — resolved inside the sandbox's home, so the provider gets
        // as far as dialling before the gate decides.
        try GitSSHTransport.register(GitKitSSHTransportProvider())
        defer { GitSSHTransport.unregister() }

        let repo = try Repository.initialize(at: tmp("GitKitSSHSandboxDest"), initialBranch: "main")
        try repo.addRemote(name: "origin", url: URL(string: "ssh://127.0.0.1:9/repo.git")!)

        let message = await shell.withCurrent {
            do {
                try repo.fetch(remote: "origin", refspec: "+refs/heads/*:refs/remotes/origin/*", progress: { _ in })
                return "fetch unexpectedly succeeded"
            } catch let error as Libgit2Error {
                return error.message
            } catch {
                return "\(error)"
            }
        }
        #expect(message.contains("host '127.0.0.1' is not in the sandbox allowlist"), "\(message)")
    }

    @Test("a clone completes while every cooperative-pool thread is blocked")
    func cloneCompletesUnderSaturatedCooperativePool() async throws {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }

        let identityPath = try ThrowawaySSHIdentity.generate(in: tmp("GitKitSSHIdentity")).privateKeyPath
        guard let sshd = try await ThrowawaySSHD.start(authorizingPublicKeyPath: identityPath + ".pub") else {
            return
        }
        defer { sshd.stop() }

        let knownHostsPath = tmp("GitKitSSHKnownHosts").path
        try sshd.knownHostsLine()
            .write(toFile: knownHostsPath, atomically: true, encoding: .utf8)
        let (configPath, alias) = try writeSSHConfig(sshd, identityPath: identityPath, knownHostsPath: knownHostsPath)

        try GitSSHTransport.register(GitKitSSHTransportProvider(sshConfigPath: configPath))
        defer { GitSSHTransport.unregister() }

        let source = try makeBareSource()
        let cloneDest = tmp("GitKitSSHSaturatedCloneDest")
        let url = URL(string: "ssh://\(alias)\(source.path)")!

        try Self.cloneWhileCooperativePoolIsSaturated(from: url, to: cloneDest)
        #expect(FileManager.default.fileExists(atPath: cloneDest.appendingPathComponent("file.txt").path))
    }

    /// Issue #290: an LFS pre-push runs on a `BlockingBridge` thread and connects to the remote
    /// from there, so the provider's own `runBlocking` (connect, then every channel read and
    /// write) nests inside a bridged call. It used to queue behind the thread it was blocking.
    @Test("a push over SSH completes when driven from inside a bridged operation")
    func pushFromBridgedOperation() async throws {
        let identityPath = try ThrowawaySSHIdentity.generate(in: tmp("GitKitSSHIdentity")).privateKeyPath
        guard let sshd = try await ThrowawaySSHD.start(authorizingPublicKeyPath: identityPath + ".pub") else {
            return
        }
        defer { sshd.stop() }

        let knownHostsPath = tmp("GitKitSSHKnownHosts").path
        try sshd.knownHostsLine()
            .write(toFile: knownHostsPath, atomically: true, encoding: .utf8)
        let (configPath, alias) = try writeSSHConfig(sshd, identityPath: identityPath, knownHostsPath: knownHostsPath)

        try GitSSHTransport.register(GitKitSSHTransportProvider(sshConfigPath: configPath))
        defer { GitSSHTransport.unregister() }

        let destBare = try makeBareDestination()
        let work = try makeWorkRepo()
        let url = URL(string: "ssh://\(alias)\(destBare.path)")!
        try runOnDetachedThread(timeoutSeconds: 60) {
            try BlockingBridge.runBlocking {
                let repo = try Repository.open(at: work)
                try repo.addRemote(name: "origin", url: url)
                try repo.push(remote: "origin", refspec: "main", setUpstream: false)
            }
        }
        let localSHA = try runGit(["rev-parse", "HEAD"], in: work)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteSHA = try runGit(["rev-parse", "main"], in: destBare)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(localSHA == remoteSHA)
    }

    /// Synchronous because `poolSaturationLock` (an `NSLock`) can't be taken from an async
    /// context. The clone runs on a plain OS thread while the pool is exhausted. It reaches the
    /// provider through libgit2 exactly as SwiftGit's clone does, so every byte goes through
    /// `BlockingBridge.runBlocking` and SSHKit's channel. Anything on that path that still
    /// needs a cooperative-pool thread deadlocks here, and the timeout turns that into a
    /// failure instead of a hung suite.
    private static func cloneWhileCooperativePoolIsSaturated(from url: URL, to destination: URL) throws {
        poolSaturationLock.lock()
        defer { poolSaturationLock.unlock() }
        let release = saturateCooperativePool(count: ProcessInfo.processInfo.activeProcessorCount)
        defer { release() }
        try runOnDetachedThread(timeoutSeconds: 60) {
            _ = try Repository.clone(from: url, to: destination)
        }
    }

    @Test("an identity not in authorized_keys surfaces OpenSSH's permission-denied wording")
    func authFailureSurfacesOpenSSHWording() async throws {
        let authorizedIdentityPath = try ThrowawaySSHIdentity.generate(
            in: tmp("GitKitSSHAuthorizedIdentity")).privateKeyPath
        guard let sshd = try await ThrowawaySSHD.start(authorizingPublicKeyPath: authorizedIdentityPath + ".pub") else {
            return
        }
        defer { sshd.stop() }

        // A second, unauthorized key pair — never written to `authorized_keys`.
        let unauthorizedIdentityPath = try ThrowawaySSHIdentity.generate(
            in: tmp("GitKitSSHUnauthorizedIdentity")).privateKeyPath

        let knownHostsPath = tmp("GitKitSSHKnownHosts").path
        try sshd.knownHostsLine()
            .write(toFile: knownHostsPath, atomically: true, encoding: .utf8)

        let (configPath, alias) = try writeSSHConfig(
            sshd, identityPath: unauthorizedIdentityPath, knownHostsPath: knownHostsPath)

        try GitSSHTransport.register(GitKitSSHTransportProvider(sshConfigPath: configPath))
        defer { GitSSHTransport.unregister() }

        let source = try makeBareSource()
        let dest = tmp("GitKitSSHAuthFailureDest")
        let repo = try Repository.initialize(at: dest, initialBranch: "main")
        try repo.addRemote(name: "origin", url: URL(string: "ssh://\(alias)\(source.path)")!)

        do {
            try repo.fetch(remote: "origin", refspec: "+refs/heads/*:refs/remotes/origin/*", progress: { _ in })
            Issue.record("expected the fetch to fail authentication")
        } catch let error as Libgit2Error {
            #expect(error.message.contains("Permission denied (publickey)."))
        }
    }

    @Test("a host key that doesn't match known_hosts surfaces OpenSSH's verification-failed wording")
    func hostKeyMismatchSurfacesOpenSSHWording() async throws {
        let identityPath = try ThrowawaySSHIdentity.generate(in: tmp("GitKitSSHIdentity")).privateKeyPath
        guard let sshd = try await ThrowawaySSHD.start(authorizingPublicKeyPath: identityPath + ".pub") else {
            return
        }
        defer { sshd.stop() }

        // A known_hosts entry for an unrelated key — never the real sshd host key.
        let wrongHostKeyIdentity = try ThrowawaySSHIdentity.generate(in: tmp("GitKitSSHWrongHostKey")).privateKeyPath
        let knownHostsPath = tmp("GitKitSSHKnownHosts").path
        try ThrowawaySSHD.knownHostsLine(hostPublicKeyPath: wrongHostKeyIdentity + ".pub", port: sshd.port)
            .write(toFile: knownHostsPath, atomically: true, encoding: .utf8)

        let (configPath, alias) = try writeSSHConfig(sshd, identityPath: identityPath, knownHostsPath: knownHostsPath)

        try GitSSHTransport.register(GitKitSSHTransportProvider(sshConfigPath: configPath))
        defer { GitSSHTransport.unregister() }

        let source = try makeBareSource()
        let dest = tmp("GitKitSSHHostKeyMismatchDest")
        let repo = try Repository.initialize(at: dest, initialBranch: "main")
        try repo.addRemote(name: "origin", url: URL(string: "ssh://\(alias)\(source.path)")!)

        do {
            try repo.fetch(remote: "origin", refspec: "+refs/heads/*:refs/remotes/origin/*", progress: { _ in })
            Issue.record("expected the fetch to fail host-key verification")
        } catch let error as Libgit2Error {
            #expect(error.message.contains("Host key verification failed."))
        }
    }

    @Test("a nonexistent remote repository path surfaces the remote's own stderr diagnostic")
    func nonexistentRemotePathSurfacesRemoteStderr() async throws {
        let identityPath = try ThrowawaySSHIdentity.generate(in: tmp("GitKitSSHIdentity")).privateKeyPath
        guard let sshd = try await ThrowawaySSHD.start(authorizingPublicKeyPath: identityPath + ".pub") else {
            return
        }
        defer { sshd.stop() }

        let knownHostsPath = tmp("GitKitSSHKnownHosts").path
        try sshd.knownHostsLine()
            .write(toFile: knownHostsPath, atomically: true, encoding: .utf8)

        let (configPath, alias) = try writeSSHConfig(sshd, identityPath: identityPath, knownHostsPath: knownHostsPath)

        try GitSSHTransport.register(GitKitSSHTransportProvider(sshConfigPath: configPath))
        defer { GitSSHTransport.unregister() }

        let missingPath = tmp("GitKitSSHMissingRepo").path
        let dest = tmp("GitKitSSHMissingRepoDest")
        let repo = try Repository.initialize(at: dest, initialBranch: "main")
        try repo.addRemote(name: "origin", url: URL(string: "ssh://\(alias)\(missingPath)")!)

        do {
            try repo.fetch(remote: "origin", refspec: "+refs/heads/*:refs/remotes/origin/*", progress: { _ in })
            Issue.record("expected the fetch to fail against a nonexistent remote path")
        } catch let error as Libgit2Error {
            #expect(error.message.contains(missingPath))
        }
    }
}
#endif
