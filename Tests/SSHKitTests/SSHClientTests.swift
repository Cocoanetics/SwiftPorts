import NIOSSH
import Testing

@testable import SSHKit

@Suite("SSHClient (in-process NIOSSH server)")
struct SSHClientTests {
    @Test func execRoundTrip() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))
        var knownHosts = KnownHostsStore()
        knownHosts.recordNewHost("127.0.0.1", publicKey: server.hostKey.publicKey, hashed: false)

        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: server.port,
            username: "sshkit-tests",
            identities: [identity],
            knownHosts: knownHosts,
            strictHostKeyChecking: .yes
        )

        let exec = try await client.exec("echo hello")
        try await exec.write(Array("hello-stdin\n".utf8))
        try await exec.closeStdin()

        var stdout: [UInt8] = []
        for await chunk in exec.stdout {
            stdout.append(contentsOf: chunk)
        }
        let exitStatus = try await exec.exitStatus

        #expect(exitStatus == 0)
        #expect(String(decoding: stdout, as: UTF8.self) == "ran: echo hello\n")

        try await client.close()
    }

    @Test func hostKeyMismatchFailsClosed() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))
        let wrongHostKey = NIOSSHPrivateKey(ed25519Key: .init())
        var knownHosts = KnownHostsStore()
        knownHosts.recordNewHost("127.0.0.1", publicKey: wrongHostKey.publicKey, hashed: false)

        await #expect(throws: SSHError.self) {
            _ = try await SSHClient.connect(
                host: "127.0.0.1",
                port: server.port,
                username: "sshkit-tests",
                identities: [identity],
                knownHosts: knownHosts,
                strictHostKeyChecking: .yes
            )
        }
    }

    @Test func newHostUnderStrictYesFailsClosed() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))

        await #expect(throws: SSHError.self) {
            _ = try await SSHClient.connect(
                host: "127.0.0.1",
                port: server.port,
                username: "sshkit-tests",
                identities: [identity],
                knownHosts: KnownHostsStore(),
                strictHostKeyChecking: .yes
            )
        }
    }

    @Test func newHostUnderAcceptNewSucceeds() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))

        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: server.port,
            username: "sshkit-tests",
            identities: [identity],
            knownHosts: KnownHostsStore(),
            strictHostKeyChecking: .acceptNew
        )
        try await client.close()
    }

    @Test func exhaustedIdentitiesSurfacesPermissionDenied() async throws {
        let server = try await InProcessSSHServer.start(authentication: .rejectAll)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))
        var knownHosts = KnownHostsStore()
        knownHosts.recordNewHost("127.0.0.1", publicKey: server.hostKey.publicKey, hashed: false)

        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: server.port,
            username: "sshkit-tests",
            identities: [identity],
            knownHosts: knownHosts,
            strictHostKeyChecking: .yes
        )

        await #expect(throws: SSHError.self) {
            _ = try await client.exec("echo hello")
        }
    }
}
