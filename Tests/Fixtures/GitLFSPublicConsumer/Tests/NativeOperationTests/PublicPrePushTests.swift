import Foundation
import GitKit
import GitLFSKit
import GitLFSTestSupport
import Testing

extension PublicOperationTests {
    @Test("pre-push borrows isolation, completes before refs and throws nonzero results",
           arguments: ["success", "rejected", "missing"])
    func prePush(outcome: String) async throws {
        try await NativeFixture.run { fixture, server in
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                let first = try fixture.seed(operation)
                let remote = fixture.path("remote.git")
                try operation.createRepository(at: remote, using: { _ in
                    try Repository.initialize(at: remote, bare: true)
                }, { _ in })
                try operation.withRepository(at: fixture.path("source")) { repository in
                    try repository.addRemote(name: "origin", url: remote)
                    // Establish the old ref, then add another LFS object locally.
                    _ = try repository.push(remote: "origin", refspecs: ["main:main"],
                        setUpstream: false, progress: { _ in })
                    try NativeFixture.otherBytes.write(to: fixture.path("source/new.lfs"))
                    try repository.add(paths: ["new.lfs"])
                    let next = try repository.commitDetailed(message: "next", author: NativeFixture.signature,
                                                              allowEmpty: false, sign: .noSign).sha
                    server.store(NativeFixture.bytes, oid: NativeFixture.pointer.oid)
                    if outcome == "rejected" {
                        server.inject(.putStatus(oid: NativeFixture.otherPointer.oid, code: 422))
                    }
                    if outcome == "missing" {
                        let object = fixture.store().objectPathname(NativeFixture.otherPointer.oid)
                        try FileManager.default.removeItem(at: object)
                    }
                    var called = 0
                    do {
                        _ = try repository.push(remote: "origin", refspecs: ["main:main", "main:new"],
                            setUpstream: false, progress: { _ in }, beforeSending: { updates in
                                called += 1
                                #expect(updates.count == 2)
                                #expect(updates.allSatisfy { $0.localOID == next })
                                let result = try PrePushOptions().run(
                                    ["origin", remote.path], updates: NativeFixture.updates(updates),
                                    at: fixture.path("source"))
                                #expect(result.status == 0)
                                #expect(server.bytes(for: NativeFixture.otherPointer.oid) == NativeFixture.otherBytes)
                                // Observe the old refs after upload and before returning to GitKit.
                                try operation.withRepository(at: remote) { bare throws in
                                    #expect(try bare.resolveOID("refs/heads/main") == first)
                                    #expect(throws: (any Error).self) { try bare.resolveOID("refs/heads/new") }
                                }
                            })
                        #expect(outcome == "success")
                    } catch let result as LFSCommandResult {
                        #expect(outcome != "success")
                        #expect(result.status != 0)
                        #expect(!result.stderr.isEmpty || !result.stdout.isEmpty)
                    }
                    #expect(called == 1)
                    try operation.withRepository(at: remote) { bare throws in
                        #expect(try bare.resolveOID("refs/heads/main") == (outcome == "success" ? next : first))
                        if outcome == "success" {
                            #expect(try bare.resolveOID("refs/heads/new") == next)
                        } else {
                            #expect(throws: (any Error).self) { try bare.resolveOID("refs/heads/new") }
                            #expect(server.bytes(for: NativeFixture.otherPointer.oid) == nil)
                        }
                    }
                    if outcome == "rejected" {
                        #expect(server.requests().contains { $0.method == "PUT" && $0.status == 422 })
                    }
                }
            }
            // A subsequent independent operation proves isolation was released.
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                try operation.withRepository(at: fixture.path("source")) { repository throws in
                    #expect(try repository.currentBranch() == "main")
                }
            }
        }
    }

    @Test("pre-push handles temporary fork remotes, actual push URLs, credentials and push leases")
    func prePushForkAndLeases() async throws {
        try await NativeFixture.run { fixture, originServer in
            try await LFSTestServer.withServer { forkServer in
                // Drop global lfs.url so per-remote URLs / push URLs select each server.
                let config = fixture.path("effective.config")
                try """
                [filter "lfs"]
                    process = git-lfs filter-process
                    clean = git-lfs clean -- %f
                    smudge = git-lfs smudge -- %f
                    required = true
                [lfs]
                    locksverify = false
                [user]
                    name = Public consumer
                    email = consumer@example.invalid
                """.write(to: config, atomically: true, encoding: .utf8)

                let forkRemote = fixture.path("fork.git")
                let first = try await GitLFSKit.withOperation(shell: fixture.shell) { operation -> String in
                    let sha = try fixture.seed(operation)
                    try operation.createRepository(at: forkRemote, using: { _ in
                        try Repository.initialize(at: forkRemote, bare: true)
                    }, { _ in })
                    try operation.withRepository(at: fixture.path("source")) { repository in
                        try repository.configSet("remote.origin.url", fixture.path("origin.git").path)
                        try repository.configSet("remote.origin.lfsurl", originServer.endpoint.absoluteString)
                        // Temporary fork remote with a distinct push URL and LFS push URL.
                        try repository.addRemote(name: "fork", url: fixture.path("unused-fetch.git"))
                        try repository.configSet("remote.fork.pushurl", forkRemote.path)
                        try repository.configSet("remote.fork.lfspushurl", forkServer.endpoint.absoluteString)
                    }
                    return sha
                }

                // Require authentication only on the fork LFS server to verify credential scoping.
                forkServer.inject(.unauthorized)
                let forkCreds: CredentialProvider = { _, _, _ in
                    .userPassword(username: "fork-user", password: "fork-secret")
                }
                let expectedAuth = "Basic " + Data("fork-user:fork-secret".utf8).base64EncodedString()

                try await GitLFSKit.withOperation(credentials: forkCreds, shell: fixture.shell) { operation in
                    try operation.withRepository(at: fixture.path("source")) { repository in
                        _ = try repository.push(
                            remote: "fork", refspecs: ["main:main"], setUpstream: false,
                            leases: PushLeases([.init(ref: "main", expectation: .absent)]),
                            connectingTo: forkRemote.path, progress: { _ in }, beforeSending: { updates in
                                _ = try PrePushOptions().run(
                                    ["fork", forkRemote.path], updates: NativeFixture.updates(updates),
                                    at: fixture.path("source"))
                            })
                    }
                }
                #expect(forkServer.bytes(for: NativeFixture.pointer.oid) == NativeFixture.bytes)
                #expect(originServer.bytes(for: NativeFixture.pointer.oid) == nil)
                #expect(forkServer.requests().contains { $0.requestHeaders["authorization"] == expectedAuth })

                // Advance local branch and test stale lease vs matching lease (explicit + trackingForRest).
                let next = try await GitLFSKit.withOperation(shell: fixture.shell) { operation -> String in
                    try operation.withRepository(at: fixture.path("source")) { repository in
                        try NativeFixture.otherBytes.write(to: fixture.path("source/new.lfs"))
                        try repository.add(paths: ["new.lfs"])
                        return try repository.commitDetailed(
                            message: "lease-next", author: NativeFixture.signature,
                            allowEmpty: false, sign: .noSign).sha
                    }
                }
                var staleCalled = 0
                try await GitLFSKit.withOperation(credentials: forkCreds, shell: fixture.shell) { operation in
                    try operation.withRepository(at: fixture.path("source")) { repository in
                        // Stale explicit lease (expects absent while remote is at `first`) refuses before upload.
                        _ = #expect(throws: PushRejectedError.self) {
                            _ = try repository.push(
                                remote: "fork", refspecs: ["main:main"], setUpstream: false,
                                leases: PushLeases([.init(ref: "main", expectation: .absent)]),
                                connectingTo: forkRemote.path, progress: { _ in },
                                beforeSending: { _ in staleCalled += 1 })
                        }
                        #expect(staleCalled == 0)
                        #expect(forkServer.bytes(for: NativeFixture.otherPointer.oid) == nil)

                        // Matching tracking lease (`refs/remotes/fork/main` == `first`) uploads before ref update.
                        _ = try repository.push(
                            remote: "fork", refspecs: ["main:main"], setUpstream: false,
                            leases: PushLeases(trackingForRest: true),
                            connectingTo: forkRemote.path, progress: { _ in }, beforeSending: { updates in
                                _ = try PrePushOptions().run(
                                    ["fork", forkRemote.path], updates: NativeFixture.updates(updates),
                                    at: fixture.path("source"))
                                try operation.withRepository(at: forkRemote) { bare throws in
                                    #expect(try bare.resolveOID("refs/heads/main") == first)
                                }
                            })
                        try repository.remoteDelete(name: "fork")
                    }
                    try operation.withRepository(at: forkRemote) { bare throws in
                        #expect(try bare.resolveOID("refs/heads/main") == next)
                    }
                }
                #expect(forkServer.bytes(for: NativeFixture.otherPointer.oid) == NativeFixture.otherBytes)
            }
        }
    }
}
