#if os(macOS) || os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import ShellKit
@testable import GitLFSKit

// Extending this serialized suite keeps its URLProtocol recorder isolated
// from the other credential tests.
extension LFSCredentialTests {
    @Test("SSH authentication overrides the request href and header",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd")))
    func sshAuthentication() async throws {
        try await host.run {
            let identity = host.root.appendingPathComponent("id_ed25519")
            let keygen = Process()
            keygen.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            keygen.arguments = ["ssh-keygen", "-t", "ed25519", "-N", "", "-f", identity.path, "-q"]
            try keygen.run()
            LFSThrowawaySSHD.waitForExit(keygen)
            #expect(keygen.terminationStatus == 0)

            let script = host.root.appendingPathComponent("authenticate")
            let executable = host.root.appendingPathComponent("git-lfs-authenticate")
            let log = host.root.appendingPathComponent("commands")
            try """
                #!/bin/sh
                printf '%s\\n' "$SSH_ORIGINAL_COMMAND" >> '\(log.path)'
                export PATH='\(host.root.path)':"$PATH"
                exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"
                """.write(to: script, atomically: true, encoding: .utf8)
            try """
                #!/bin/sh
                if [ "$1" = "failure" ]; then
                    printf '  not allowed\\n' >&2
                    exit 7
                fi
                if [ "$1" = "unavailable" ]; then
                    printf 'bash: git-lfs-authenticate: command not found\\n' >&2
                    exit 1
                fi
                [ "$#" = 2 ] || exit 8
                [ "$1" = "org/o'neil repo.git" ] || exit 9
                printf '%s\\n' '{"href":"https://lfs.example/alternate/?token=abc",'\
                '"header":{"Authorization":"RemoteAuth secret","X-LFS-SSH":"yes"},"expires_in":3600}'
                """.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let sshd = try #require(try await LFSThrowawaySSHD.start(
                authorizingPublicKeyPath: identity.path + ".pub", forcedCommand: script.path))
            defer { sshd.stop() }

            let sshDirectory = host.home.appendingPathComponent(".ssh")
            try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
            let hostKey = try String(contentsOfFile: sshd.hostPublicKeyPath, encoding: .utf8).split(separator: " ")
            let knownHosts = sshDirectory.appendingPathComponent("known_hosts")
            try "[127.0.0.1]:\(sshd.port) \(hostKey[0]) \(hostKey[1])\n"
                .write(to: knownHosts, atomically: true, encoding: .utf8)
            try """
                Host lfs-test-alias
                    HostName 127.0.0.1
                    Port \(sshd.port)
                    User \(ProcessInfo.processInfo.environment["USER"] ?? NSUserName())
                    IdentityFile \(identity.path)
                    UserKnownHostsFile \(knownHosts.path)
                    StrictHostKeyChecking yes
                """.write(to: sshDirectory.appendingPathComponent("config"), atomically: true, encoding: .utf8)

            LFSMockURLProtocol.install { request in
                if request.url?.host == "foreign.example" {
                    return (request.value(forHTTPHeaderField: "Authorization") == nil ? 200 : 403, Data())
                }
                let valid = request.url?.absoluteString == "https://lfs.example/alternate/objects/batch?token=abc"
                    && request.value(forHTTPHeaderField: "Authorization") == "RemoteAuth secret"
                    && request.value(forHTTPHeaderField: "X-LFS-SSH") == "yes"
                    && Self.requestBody(request) == Data("{\"operation\":\"download\"}".utf8)
                return (valid ? 200 : 403, Data("{\"objects\":[]}".utf8))
            }
            defer { LFSMockURLProtocol.reset() }
            let fixture = try await LFSFixture.make(host, "ssh-request", remotes: [
                ("origin", "lfs-test-alias:org/o'neil repo.git")], config: [
                    ("lfs.ssh.retries", "1"),
                    ("http.https://lfs.example/alternate.extraheader", "Authorization: Basic configured")])
            let client = await LFSClient(git: fixture.client, session: LFSMockURLProtocol.session())
            let endpoint = client.finder.endpoint(operation: "download", remote: "origin")
            var request = URLRequest(url: try #require(URL(string: endpoint.url + "/objects/batch")))
            request.httpMethod = "POST"
            request.httpBody = Data("{\"operation\":\"download\"}".utf8)
            for _ in 0..<2 {
                #expect(try await client.data(for: request, operation: "download") == Data("{\"objects\":[]}".utf8))
            }
            let requests = LFSMockURLProtocol.requests()
            #expect(requests.count == 2)
            #expect(requests.first?.httpMethod == "POST")
            let commands = try String(contentsOf: log, encoding: .utf8).split(whereSeparator: \.isNewline)
            #expect(commands == ["git-lfs-authenticate 'org/o'\\''neil repo.git' download"])
            let foreign = URLRequest(url: try #require(URL(string: "https://foreign.example/object")))
            _ = try await client.data(for: foreign, operation: "download")
            _ = try await client.ssh.resolve(
                client.finder.endpoint(operation: "upload", remote: "origin"), method: "POST")
            #expect(try String(contentsOf: log, encoding: .utf8).contains(" upload"))

            var failed = endpoint
            failed.ssh.path = "failure"
            await #expect(throws: LFSClientError("not allowed: exit status 7")) {
                try await client.ssh.resolve(failed, method: "GET")
            }
            let failures = try String(contentsOf: log, encoding: .utf8)
                .split(whereSeparator: \.isNewline).filter { $0.contains(" failure ") }
            #expect(failures.count == 2)

            var unavailable = endpoint
            unavailable.ssh.path = "unavailable"
            #expect(try await client.ssh.resolve(unavailable, method: "GET").href.isEmpty)
            let unavailableCommands = try String(contentsOf: log, encoding: .utf8)
                .split(whereSeparator: \.isNewline).filter { $0.contains(" unavailable ") }
            #expect(unavailableCommands.count == 1)
        }
    }

    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        var count = stream.read(&buffer, maxLength: buffer.count)
        while count > 0 {
            data.append(contentsOf: buffer.prefix(count))
            count = stream.read(&buffer, maxLength: buffer.count)
        }
        return data
    }
}
#endif
