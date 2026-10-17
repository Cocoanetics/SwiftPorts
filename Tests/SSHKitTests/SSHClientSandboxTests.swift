// Gated off Windows for the same reason as `SSHClientTests`: a real handshake traps in
// swift-nio-ssh 0.15.0's `CSPRNG` there.
#if !os(Windows)
import Foundation
import ShellKit
import Testing

@testable import SSHKit

/// `SSHClient` inside an embedding shell that binds a ShellKit sandbox — the way SwiftBash runs
/// `ssh` and GitKitSSH: identity files resolve against that shell (issue #121), and the
/// connection itself goes through its network gate (issue #122).
@Suite("SSHClient under a sandboxed Shell")
struct SSHClientSandboxTests {
    /// Exists only in the sandbox's home — a name no real `~/.ssh` has, so resolving against the
    /// host's home instead finds nothing (and never reads a real key).
    private static let sandboxOnlyKeyName = "id_sshkit_sandbox_only"

    private static func makeSandboxRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHClientSandboxTests-\(UUID().uuidString)")
        let sshDirectory = root.appendingPathComponent("home/.ssh")
        try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: SSHKitFixtures.path("id_ed25519_test"),
            toPath: sshDirectory.appendingPathComponent(Self.sandboxOnlyKeyName).path)
        return root
    }

    /// `connect(identityFiles:)` decrypts identities from a task spawned on a NIO event-loop
    /// callback, which inherits no task-locals — `~` must still mean the connecting shell's home.
    @Test func lazyIdentitiesResolveAgainstTheConnectingShell() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey)
        defer { Task { try? await server.shutdown() } }
        let root = try Self.makeSandboxRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = Shell(
            environment: Environment(),
            sandbox: Sandbox.rooted(at: root, allowedHosts: ["127.0.0.1"]))

        let output = try await shell.withCurrent {
            let client = try await SSHClient.connect(
                host: "127.0.0.1",
                port: server.port,
                username: "sshkit-tests",
                identityFiles: ["~/.ssh/\(Self.sandboxOnlyKeyName)"],
                passphrasePrompt: { _ in nil },
                knownHosts: KnownHostsStore(),
                strictHostKeyChecking: .acceptNew
            )
            let exec = try await client.exec("echo hello")
            var stdout: [UInt8] = []
            for await chunk in exec.stdout {
                stdout.append(contentsOf: chunk)
            }
            _ = try await exec.exitStatus
            try await client.close()
            return String(decoding: stdout, as: UTF8.self)
        }

        #expect(output == "ran: echo hello\n")
    }

    /// A sandbox that allows no hosts must stop the connection before it is dialled — the server
    /// is reachable, so getting anything but the sandbox's denial means the gate was skipped.
    @Test func connectAsksTheSandboxBeforeDialling() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey)
        defer { Task { try? await server.shutdown() } }
        let root = try Self.makeSandboxRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = Shell(environment: Environment(), sandbox: Sandbox.rooted(at: root))

        let denial = await #expect(throws: Sandbox.Denial.self) {
            try await shell.withCurrent {
                let client = try await SSHClient.connect(
                    host: "127.0.0.1",
                    port: server.port,
                    username: "sshkit-tests",
                    identityFiles: ["~/.ssh/\(Self.sandboxOnlyKeyName)"],
                    passphrasePrompt: { _ in nil },
                    knownHosts: KnownHostsStore(),
                    strictHostKeyChecking: .acceptNew
                )
                try await client.close()
            }
        }
        #expect(denial?.url.absoluteString == "ssh://127.0.0.1:\(server.port)")
        #expect(denial?.reason == "host '127.0.0.1' is not in the sandbox allowlist")
    }

    @Test func networkAuthorizationURLKeepsTheDialledHost() {
        let cases: [(host: String, port: Int, url: String)] = [
            ("github.com", 22, "ssh://github.com:22"),
            ("127.0.0.1", 2222, "ssh://127.0.0.1:2222"),
            ("::1", 2222, "ssh://[::1]:2222"),
            ("[::1]", 22, "ssh://[::1]:22"),
            ("fe80::1%en0", 22, "ssh://[fe80::1%25en0]:22"),
        ]
        for testCase in cases {
            let url = SSHClient.networkAuthorizationURL(host: testCase.host, port: testCase.port)
            #expect(url.absoluteString == testCase.url)
            #expect(url.host == testCase.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        }
    }
}
#endif
