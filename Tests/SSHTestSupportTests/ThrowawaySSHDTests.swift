#if os(macOS) || os(Linux)
import Foundation
import SSHTestSupport
import Testing

/// The public surface downstream test targets link through the `SSHTestSupport` product
/// (issue #292). Skips the daemon-backed checks when no system `sshd` is available.
@Suite("ThrowawaySSHD")
struct ThrowawaySSHDTests {
    private func tmp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
    }

    @Test func knownHostsLineBracketsNonDefaultPorts() throws {
        let path = tmp("SSHTestSupportKey").path
        try "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample comment here\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(try ThrowawaySSHD.knownHostsLine(hostPublicKeyPath: path, port: 2222)
            == "[127.0.0.1]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample")
        #expect(try ThrowawaySSHD.knownHostsLine(hostPublicKeyPath: path, port: 22)
            == "127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample")
    }

    @Test func startsPinsAndAliasesADaemon() async throws {
        let directory = tmp("SSHTestSupport Identity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try ThrowawaySSHIdentity.generate(in: directory)
        #expect(FileManager.default.fileExists(atPath: identity.privateKeyPath))
        #expect(FileManager.default.fileExists(atPath: identity.publicKeyPath))

        guard let sshd = try await ThrowawaySSHD.start(authorizingPublicKeyPath: identity.publicKeyPath) else {
            return
        }
        defer { sshd.stop() }
        #expect(sshd.port > 0)

        let hostKey = try String(contentsOfFile: sshd.hostPublicKeyPath, encoding: .utf8).split(separator: " ")
        #expect(try sshd.knownHostsLine() == "[127.0.0.1]:\(sshd.port) \(hostKey[0]) \(hostKey[1])")

        let knownHostsPath = directory.appendingPathComponent("known_hosts").path
        try sshd.knownHostsLine().write(toFile: knownHostsPath, atomically: true, encoding: .utf8)
        let configPath = directory.appendingPathComponent("config/ssh_config").path
        try sshd.writeSSHConfig(
            to: configPath, alias: "throwaway", identityPath: identity.privateKeyPath,
            knownHostsPath: knownHostsPath)
        let lines = try String(contentsOfFile: configPath, encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.first == "Host throwaway")
        #expect(lines.contains("HostName 127.0.0.1"))
        #expect(lines.contains("Port \(sshd.port)"))
        #expect(lines.contains("IdentityFile \"\(identity.privateKeyPath)\""))
        #expect(lines.contains("IdentitiesOnly yes"))
        #expect(lines.contains("UserKnownHostsFile \"\(knownHostsPath)\""))
        #expect(lines.contains("StrictHostKeyChecking yes"))

        // The system client reaches the daemon through the alias, pinned key and identity alone,
        // with every path under a directory whose name contains a space.
        #expect(try Self.systemSSH(configPath: configPath, alias: "throwaway", command: "echo ok") == "ok\n")
    }

    private static func systemSSH(configPath: String, alias: String, command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ssh", "-F", configPath, "-o", "BatchMode=yes", alias, command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        ThrowawaySSHD.waitForExit(process, timeout: 60)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : ""
    }
}
#endif
