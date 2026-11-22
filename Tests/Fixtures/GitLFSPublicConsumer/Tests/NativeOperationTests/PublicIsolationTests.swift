import Foundation
import GitKit
import GitLFSKit
import GitLFSTestSupport
import ShellKit
import Testing

extension PublicOperationTests {
    @Test("secondary include authorization retries preparation without replaying mutation or claims",
           arguments: [false, true])
    func includes(deny: Bool) async throws {
        try await NativeFixture.run { fixture, _ in
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                _ = try fixture.seed(operation)
                _ = try fixture.seed(operation, name: "secondary")
            }
            let included = fixture.path("late.config")
            try "[consumer]\n included = yes\n".write(to: included, atomically: true, encoding: .utf8)
            // The secondary config is first read after an observable host mutation.
            let config = fixture.path("secondary/.git/config")
            let previous = try String(contentsOf: config, encoding: .utf8)
            try (previous + "\n[include]\n path = ../../late.config\n")
                .write(to: config, atomically: true, encoding: .utf8)
            fixture.shell.sandbox = fixture.sandbox { url in
                if deny, url.lastPathComponent == "late.config" {
                    throw Sandbox.Denial(url: url, reason: "include denied")
                }
            }
            var mutations = 0
            var claims = 0
            do {
                try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                    mutations += 1
                    try operation.withRepository(at: fixture.path("source")) { repository in
                        try repository.configSet("consumer.mutation", "once")
                        claims += 1
                        try operation.withRepository(at: fixture.path("secondary")) { secondary throws in
                            #expect(try secondary.configGet("consumer.included") == "yes")
                            #expect(try secondary.configGet("consumer.operation") == "scoped")
                        }
                    }
                }
                #expect(!deny)
            } catch let error as Sandbox.Denial {
                #expect(deny)
                #expect(error.url.lastPathComponent == "late.config")
            }
            #expect(mutations == 1)
            #expect(claims == 1)
        }
    }

    @Test("operation credentials stay local across a 401 retry", arguments: ["one", "two"])
    func credentials(password: String) async throws {
        try await NativeFixture.run { fixture, server in
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in _ = try fixture.seed(operation) }
            server.store(NativeFixture.bytes, oid: NativeFixture.pointer.oid)
            try FileManager.default.removeItem(at: fixture.store().objectPathname(NativeFixture.pointer.oid))
            server.inject(.unauthorized)
            let credentials: CredentialProvider = { _, _, _ in
                .userPassword(username: "consumer", password: password)
            }
            try await GitLFSKit.withOperation(credentials: credentials, shell: fixture.shell) { operation in
                try operation.withRepository(at: fixture.path("source")) { repository in
                    try FileManager.default.removeItem(at: fixture.path("source/a.lfs"))
                    try repository.checkoutPaths(["a.lfs"])
                    #expect(try Data(contentsOf: fixture.path("source/a.lfs")) == NativeFixture.bytes)
                }
            }
            let authorization = "Basic " + Data("consumer:\(password)".utf8).base64EncodedString()
            #expect(server.requests().contains { $0.status == 401 })
            #expect(server.requests().contains { $0.requestHeaders["authorization"] == authorization })
            #expect(!server.requests().contains {
                $0.requestHeaders["authorization"].map { $0 != authorization } ?? false
            })
        }
    }

    @Test("escaped scope and preparation are revoked and a following operation succeeds")
    func lifetime() async throws {
        try await NativeFixture.run { fixture, _ in
            var escaped: GitLFSKit.Operation?
            var escapedPreparation: RepositoryPreparation?
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                escaped = operation
                escapedPreparation = operation.preparation
                _ = try fixture.seed(operation)
            }
            #expect(throws: (any Error).self) {
                try escaped?.withRepository(at: fixture.path("source")) { _ in Issue.record("expired scope ran") }
            }
            let escapedClone = fixture.path("escaped-clone")
            #expect(throws: (any Error).self) {
                _ = try Repository.clone(
                    from: fixture.path("source"), to: escapedClone, progress: { _ in },
                    preparation: try #require(escapedPreparation))
            }
            #expect(!FileManager.default.fileExists(atPath: escapedClone.path))
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                try operation.withRepository(at: fixture.path("source")) { repository throws in
                    #expect(try repository.status().isClean)
                }
            }
        }
    }

    @Test("cancelling an active bridged upload prevents refs and releases isolation")
    func cancellation() async throws {
        try await NativeFixture.run { fixture, server in
            let remote = fixture.path("remote.git")
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                _ = try fixture.seed(operation)
                try operation.createRepository(at: remote, using: { _ in
                    try Repository.initialize(at: remote, bare: true)
                }, { _ in })
                try operation.withRepository(at: fixture.path("source")) { repository in
                    try repository.addRemote(name: "origin", url: remote)
                    try NativeFixture.otherBytes.write(to: fixture.path("source/new.lfs"))
                    try repository.add(paths: ["new.lfs"])
                    _ = try repository.commitDetailed(message: "next", author: NativeFixture.signature,
                                                       allowEmpty: false, sign: .noSign)
                }
            }
            await server.holdObjectTransfers(untilInFlight: 100, timeout: .seconds(20))
            let task = Task {
                try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                    try operation.withRepository(at: fixture.path("source")) { repository in
                        _ = try repository.push(remote: "origin", refspecs: ["main:main"],
                            setUpstream: false, progress: { _ in }, beforeSending: { updates in
                                _ = try PrePushOptions().run(["origin", remote.path],
                                    updates: NativeFixture.updates(updates), at: fixture.path("source"))
                            })
                    }
                }
            }
            while await server.peakObjectTransfers() == 0 { await Task.yield() }
            // A later operation waits for the active push's turn. Cancellation
            // must prevent it from entering the host transaction when admitted.
            let queued = Task {
                try await GitLFSKit.withOperation(shell: fixture.shell) { _ in
                    Issue.record("cancelled queued operation entered its body")
                }
            }
            queued.cancel()
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            await #expect(throws: CancellationError.self) { try await queued.value }
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                try operation.withRepository(at: remote) { repository throws in
                    _ = #expect(throws: (any Error).self) { try repository.resolveOID("refs/heads/main") }
                }
                #expect(try FileManager.default.contentsOfDirectory(
                    at: fixture.store().temporaryDirectory, includingPropertiesForKeys: nil).isEmpty)
            }
        }
    }
}
