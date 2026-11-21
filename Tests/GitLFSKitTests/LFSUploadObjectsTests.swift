import Foundation
import GitLFSTestSupport
import Testing
@testable import GitLFSKit

@Suite("LFS uploadObjects(for:) (git-lfs 3.7.1 uploader.go)")
struct LFSUploadObjectsTests {
    let first = Data("first object\n".utf8)
    let second = Data("second object!\n".utf8)
    static let zero = String(repeating: "0", count: 40)
    static let hint = """
    hint: Your push was rejected due to missing or corrupt local objects.
    hint: You can disable this check with: `git config lfs.allowincompletepush true`

    """

    func oid(_ data: Data) -> String { LFSServerRepository.oid(data) }

    func puts(_ server: LFSTestServer) -> Set<String> {
        Set(server.requests().filter { $0.method == "PUT" }.map(\.path))
    }

    func update(_ local: String, remote: String = zero) -> LFSRefUpdate {
        LFSRefUpdate(localRef: "refs/heads/main", localOID: local, remoteRef: "refs/heads/main", remoteOID: remote)
    }

    /// Two commits, `first` then `second`, both objects local. Returns both commits.
    func history(_ repo: LFSServerRepository) async throws -> (String, String) {
        try await repo.storeLocally(first)
        try await repo.storeLocally(second)
        let one = try await repo.commit([("a.dat", first)], message: "one")
        let two = try await repo.commit([("b.dat", second)], message: "two")
        return (one, two)
    }

    @Test("a zero remote OID with no remote-tracking refs uploads the whole history")
    func zeroRemote() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                let (_, two) = try await history(repo)
                let result = try await repo.uploadObjects(for: [update(two)], git: repo.git)
                #expect(result.status == 0)
                #expect(result.stderr == "")
                #expect(result.stdout == "Uploading LFS objects: 100% (2/2), 28 B | 0 B/s, done.\n")
                #expect(puts(server) == ["/objects/\(oid(first))", "/objects/\(oid(second))"])
                #expect(server.bytes(for: oid(second)) == second)
            }
        }
    }

    @Test("remote-tracking tips are excluded")
    func remoteTrackingTips() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                let (one, two) = try await history(repo)
                try await repo.setReference("refs/remotes/origin/main", to: one)
                try await repo.setReference("refs/remotes/upstream/main", to: two)
                let result = try await repo.uploadObjects(for: [update(two)], git: repo.git)
                #expect(result.status == 0)
                #expect(puts(server) == ["/objects/\(oid(second))"])
            }
        }
    }

    @Test("only remote-tracking tips whose branch the remote still lists are excluded")
    func advertisedBranches() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                let (one, two) = try await history(repo)
                try await repo.setReference("refs/remotes/origin/main", to: one)
                try await repo.setReference("refs/remotes/origin/topic", to: two)
                // Unknown, or nothing listed matches: every tip is excluded.
                _ = try await repo.uploadObjects(for: [update(two)], git: repo.git)
                _ = try await repo.uploadObjects(for: [update(two)], remoteBranches: ["gone"], git: repo.git)
                #expect(server.requests().isEmpty)
                // topic was deleted on the server, so its tip is no exclusion.
                let result = try await repo.uploadObjects(
                    for: [update(two)], remoteBranches: ["refs/heads/main"], git: repo.git)
                #expect(result.status == 0)
                #expect(puts(server) == ["/objects/\(oid(second))"])
            }
        }
    }

    // Needs URLSession to report a 1 MB body's sent bytes. On Windows that
    // upload to the in-process server stalls (no PUT ever completes; CI ran
    // into the 10-minute mark), so the test is limited to the other platforms.
    #if !os(Windows)
    @Test("a failed PUT takes back its bytes, so the retry is counted once")
    func retriedUploadProgress() async throws {
        let large = Data(repeating: 0x61, count: 1_000_000)
        try await LFSTestServer.withServer { server in
            server.inject(.putStatus(oid: oid(large), code: 503))
            try await LFSServerRepository.run(server) { repo in
                try await repo.storeLocally(large)
                let tip = try await repo.commit([("large.dat", large)])
                let result = try await repo.uploadObjects(for: [update(tip)], git: repo.git)
                #expect(result.status == 0)
                #expect(result.stdout.hasPrefix("Uploading LFS objects: 100% (1/1), 1.0 MB | "))
                #expect(server.requests().filter { $0.method == "PUT" }.map(\.status) == [503, 200])
                #expect(server.bytes(for: oid(large)) == large)
            }
        }
    }
    #endif

    @Test("a non-zero remote OID is excluded")
    func nonZeroRemote() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                let (one, two) = try await history(repo)
                let result = try await repo.uploadObjects(for: [update(two, remote: one)], git: repo.git)
                #expect(result.status == 0)
                #expect(result.stdout == "Uploading LFS objects: 100% (1/1), 15 B | 0 B/s, done.\n")
                #expect(puts(server) == ["/objects/\(oid(second))"])
            }
        }
    }

    @Test("a zero local OID (a deletion) uploads nothing")
    func zeroLocal() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                _ = try await history(repo)
                let result = try await repo.uploadObjects(for: [update(Self.zero)], git: repo.git)
                #expect(result.status == 0)
                #expect(result.stdout == "")
                #expect(result.stderr == "")
                #expect(server.requests().isEmpty)
            }
        }
    }

    @Test("an object the server already has counts as finished")
    func serverHasObject() async throws {
        try await LFSTestServer.withServer { server in
            server.store(first, oid: oid(first))
            try await LFSServerRepository.run(server) { repo in
                let (_, two) = try await history(repo)
                let result = try await repo.uploadObjects(for: [update(two)], git: repo.git)
                #expect(result.status == 0)
                #expect(result.stdout == "Uploading LFS objects: 100% (2/2), 28 B | 0 B/s, done.\n")
                #expect(puts(server) == ["/objects/\(oid(second))"])
            }
        }
    }

    @Test("a missing object rejects the push and uploads nothing")
    func missingObject() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                try await repo.storeLocally(first)
                let tip = try await repo.commit([("a.dat", first), ("missing.dat", second)])
                let result = try await repo.uploadObjects(for: [update(tip)], git: repo.git)
                #expect(result.status == 2)
                #expect(result.stderr == "")
                #expect(result.stdout == """
                Uploading LFS objects:   0% (0/2), 0 B | 0 B/s, done.
                Git LFS upload failed:
                  (missing) missing.dat (\(oid(second)))

                """ + Self.hint)
                #expect(puts(server).isEmpty)
            }
        }
    }

    @Test("a missing object the server has is not an error")
    func missingButOnServer() async throws {
        try await LFSTestServer.withServer { server in
            server.store(second, oid: oid(second))
            try await LFSServerRepository.run(server) { repo in
                let tip = try await repo.commit([("missing.dat", second)])
                let result = try await repo.uploadObjects(for: [update(tip)], git: repo.git)
                #expect(result.status == 0)
                #expect(result.stdout == "Uploading LFS objects: 100% (1/1), 15 B | 0 B/s, done.\n")
            }
        }
    }

    @Test("a corrupt object rejects the push; the others still upload")
    func corruptObject() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                try await repo.storeLocally(first)
                try Data("short".utf8).write(to: try await repo.store.objectPath(oid(second)))
                let tip = try await repo.commit([("a.dat", first), ("bad.dat", second)])
                let result = try await repo.uploadObjects(for: [update(tip)], git: repo.git)
                #expect(result.status == 2)
                #expect(result.stdout.hasSuffix("""
                Git LFS upload failed:
                  (corrupt) bad.dat (\(oid(second)))

                """ + Self.hint))
                #expect(puts(server) == ["/objects/\(oid(first))"])
            }
        }
    }

    @Test("lfs.allowincompletepush lists missing objects and uploads the present ones")
    func allowIncompletePush() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server, config: [("lfs.allowincompletepush", "true")]) { repo in
                try await repo.storeLocally(first)
                let tip = try await repo.commit([("a.dat", first), ("missing.dat", second)])
                let result = try await repo.uploadObjects(for: [update(tip)], git: repo.git)
                #expect(result.status == 0)
                #expect(result.stderr == "")
                #expect(result.stdout == """
                Uploading LFS objects:  50% (1/2), 13 B | 0 B/s, done.
                Git LFS upload missing objects:
                  (missing) missing.dat (\(oid(second)))

                """)
                #expect(puts(server) == ["/objects/\(oid(first))"])
            }
        }
    }

    @Test("--dry-run prints each object once and contacts no server")
    func dryRun() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                let (one, two) = try await history(repo)
                let updates = [update(one), update(two)]
                let result = try await repo.uploadObjects(for: updates, dryRun: true, git: repo.git)
                #expect(result.status == 0)
                #expect(result.stderr == "")
                #expect(result.stdout == """
                push \(oid(first)) => a.dat
                push \(oid(second)) => b.dat

                """)
                #expect(server.requests().isEmpty)
            }
        }
    }

    @Test("the batch ref is the update's remote ref")
    func batchRef() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                let (_, two) = try await history(repo)
                let update = LFSRefUpdate(localRef: "refs/heads/main", localOID: two,
                                          remoteRef: "refs/heads/release", remoteOID: Self.zero)
                _ = try await repo.uploadObjects(for: [update], git: repo.git)
                let batch = try #require(server.requests().first { $0.path == "/objects/batch" })
                let body = String(decoding: batch.requestBody, as: UTF8.self)
                #expect(body.contains(#""ref":{"name":"refs/heads/release"}"#))
            }
        }
    }
}
