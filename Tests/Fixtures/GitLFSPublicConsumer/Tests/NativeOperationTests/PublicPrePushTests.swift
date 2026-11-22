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
                try operation.createRepository(at: remote, using: {
                    _ = try Repository.initialize(at: remote, bare: true)
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
}
