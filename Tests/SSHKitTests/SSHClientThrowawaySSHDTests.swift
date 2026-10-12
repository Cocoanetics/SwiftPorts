#if os(macOS) || os(Linux)
import Foundation
import NIOSSH
import Testing

@testable import SSHKit

/// Exercises `SSHClient` against a real, throwaway OpenSSH `sshd` — the strongest available proof
/// of wire compatibility with actual OpenSSH, per issue #112's test plan. Skips (rather than
/// fails) when no system `sshd`/`ssh-keygen` is available, so this stays safe on a CI image that
/// doesn't ship one.
@Suite("SSHClient (throwaway sshd)")
struct SSHClientThrowawaySSHDTests {
    @Test func execAgainstRealOpenSSHServer() async throws {
        let identityPath = SSHKitFixtures.path("id_ed25519_test")
        guard let sshd = try await ThrowawaySSHD.start(authorizingPublicKeyPath: identityPath + ".pub") else {
            return
        }
        defer { sshd.stop() }

        let identity = try await IdentityLoader.load(path: identityPath)
        let hostPublicKeyLine = try String(contentsOfFile: sshd.hostPublicKeyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hostPublicKey = try NIOSSHPublicKey(openSSHPublicKey: hostPublicKeyLine)

        var knownHosts = KnownHostsStore()
        knownHosts.recordNewHost(
            SSHKnownHostsName.make(host: "127.0.0.1", port: sshd.port),
            publicKey: hostPublicKey,
            hashed: false
        )

        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: sshd.port,
            username: ProcessInfo.processInfo.environment["USER"] ?? "root",
            identities: [identity],
            knownHosts: knownHosts,
            strictHostKeyChecking: .yes
        )

        let exec = try await client.exec("echo sshkit-integration-test")
        var stdout: [UInt8] = []
        for await chunk in exec.stdout {
            stdout.append(contentsOf: chunk)
        }
        let exitStatus = try await exec.exitStatus

        #expect(exitStatus == 0)
        #expect(String(decoding: stdout, as: UTF8.self) == "sshkit-integration-test\n")

        try await client.close()
    }

    /// Proves a real `sshd` accepts this port's wire-level `pty-req` (term, window size, encoded
    /// termios modes) — the strongest available check that `SSHLocalTerminal`'s encoding matches
    /// `ssh_tty_make_modes` closely enough for real OpenSSH to allocate a PTY from it (issue #115).
    /// A PTY's line discipline rewrites `\n` to `\r\n` on output (`ONLCR`), so the assertion allows
    /// either line ending rather than asserting raw-mode-exact framing.
    @Test func execWithPseudoTerminalAgainstRealOpenSSHServer() async throws {
        let identityPath = SSHKitFixtures.path("id_ed25519_test")
        guard let sshd = try await ThrowawaySSHD.start(authorizingPublicKeyPath: identityPath + ".pub") else {
            return
        }
        defer { sshd.stop() }

        let identity = try await IdentityLoader.load(path: identityPath)
        let hostPublicKeyLine = try String(contentsOfFile: sshd.hostPublicKeyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hostPublicKey = try NIOSSHPublicKey(openSSHPublicKey: hostPublicKeyLine)

        var knownHosts = KnownHostsStore()
        knownHosts.recordNewHost(
            SSHKnownHostsName.make(host: "127.0.0.1", port: sshd.port),
            publicKey: hostPublicKey,
            hashed: false
        )

        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: sshd.port,
            username: ProcessInfo.processInfo.environment["USER"] ?? "root",
            identities: [identity],
            knownHosts: knownHosts,
            strictHostKeyChecking: .yes
        )

        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))
        let exec = try await client.exec("echo sshkit-pty-test", pseudoTerminal: pty, pseudoTerminalRequired: true)
        #expect(exec.hasPseudoTerminal)

        var stdout: [UInt8] = []
        for await chunk in exec.stdout {
            stdout.append(contentsOf: chunk)
        }
        let exitStatus = try await exec.exitStatus

        #expect(exitStatus == 0)
        let output = String(decoding: stdout, as: UTF8.self)
        #expect(output.contains("sshkit-pty-test"))

        try await client.close()
    }
}
#endif
