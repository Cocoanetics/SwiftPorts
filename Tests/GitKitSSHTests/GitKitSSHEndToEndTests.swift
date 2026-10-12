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
        process.waitUntilExit()
        let outStr = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        if process.terminationStatus != 0 {
            let errStr = String(decoding: (try? err.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            throw Failure("git \(args.joined(separator: " ")) failed: \(errStr)")
        }
        return outStr
    }

    /// Generates a throwaway ed25519 key pair, returning the private key path.
    private func makeIdentity(in directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("id_ed25519").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ssh-keygen", "-t", "ed25519", "-N", "", "-f", path, "-q"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure("ssh-keygen failed")
        }
        return path
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

    private func knownHostsLine(hostPublicKeyPath: String, port: Int) throws -> String {
        let keyLine = try String(contentsOfFile: hostPublicKeyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = keyLine.split(separator: " ", maxSplits: 2)
        let hostField = port == 22 ? "127.0.0.1" : "[127.0.0.1]:\(port)"
        return "\(hostField) \(fields[0]) \(fields[1])"
    }

    /// Writes an `ssh_config` with one `Host` alias resolving to the throwaway sshd, and returns
    /// its path alongside the alias to put in a git `ssh://` URL.
    private func writeSSHConfig(
        directory: URL, port: Int, identityPath: String, knownHostsPath: String,
        strictHostKeyChecking: String = "yes"
    ) throws -> (configPath: String, alias: String) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let alias = "gitkitssh-test-host"
        let configPath = directory.appendingPathComponent("ssh_config").path
        let config = """
            Host \(alias)
                HostName 127.0.0.1
                Port \(port)
                User \(ProcessInfo.processInfo.environment["USER"] ?? "root")
                IdentityFile \(identityPath)
                UserKnownHostsFile \(knownHostsPath)
                StrictHostKeyChecking \(strictHostKeyChecking)
            """
        try config.write(toFile: configPath, atomically: true, encoding: .utf8)
        return (configPath, alias)
    }

    @Test("clone, fetch and push carry real bytes over the registered SSHKit transport")
    func cloneFetchAndPush() async throws {
        let identityPath = try makeIdentity(in: tmp("GitKitSSHIdentity"))
        guard let sshd = try await ThrowawaySSHD.start(authorizingPublicKeyPath: identityPath + ".pub") else {
            return
        }
        defer { sshd.stop() }

        let knownHostsPath = tmp("GitKitSSHKnownHosts").path
        try knownHostsLine(hostPublicKeyPath: sshd.hostPublicKeyPath, port: sshd.port)
            .write(toFile: knownHostsPath, atomically: true, encoding: .utf8)

        let (configPath, alias) = try writeSSHConfig(
            directory: tmp("GitKitSSHConfig"), port: sshd.port,
            identityPath: identityPath, knownHostsPath: knownHostsPath)

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

    @Test("an identity not in authorized_keys surfaces OpenSSH's permission-denied wording")
    func authFailureSurfacesOpenSSHWording() async throws {
        let authorizedIdentityPath = try makeIdentity(in: tmp("GitKitSSHAuthorizedIdentity"))
        guard let sshd = try await ThrowawaySSHD.start(authorizingPublicKeyPath: authorizedIdentityPath + ".pub") else {
            return
        }
        defer { sshd.stop() }

        // A second, unauthorized key pair — never written to `authorized_keys`.
        let unauthorizedIdentityPath = try makeIdentity(in: tmp("GitKitSSHUnauthorizedIdentity"))

        let knownHostsPath = tmp("GitKitSSHKnownHosts").path
        try knownHostsLine(hostPublicKeyPath: sshd.hostPublicKeyPath, port: sshd.port)
            .write(toFile: knownHostsPath, atomically: true, encoding: .utf8)

        let (configPath, alias) = try writeSSHConfig(
            directory: tmp("GitKitSSHConfig"), port: sshd.port,
            identityPath: unauthorizedIdentityPath, knownHostsPath: knownHostsPath)

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
        let identityPath = try makeIdentity(in: tmp("GitKitSSHIdentity"))
        guard let sshd = try await ThrowawaySSHD.start(authorizingPublicKeyPath: identityPath + ".pub") else {
            return
        }
        defer { sshd.stop() }

        // A known_hosts entry for an unrelated key — never the real sshd host key.
        let wrongHostKeyIdentity = try makeIdentity(in: tmp("GitKitSSHWrongHostKey"))
        let knownHostsPath = tmp("GitKitSSHKnownHosts").path
        try knownHostsLine(hostPublicKeyPath: wrongHostKeyIdentity + ".pub", port: sshd.port)
            .write(toFile: knownHostsPath, atomically: true, encoding: .utf8)

        let (configPath, alias) = try writeSSHConfig(
            directory: tmp("GitKitSSHConfig"), port: sshd.port,
            identityPath: identityPath, knownHostsPath: knownHostsPath)

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
}
#endif
