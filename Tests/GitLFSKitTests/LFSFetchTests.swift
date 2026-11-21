import Foundation
import GitLFSTestSupport
import Testing
@testable import GitLFSKit

@Suite("LFS fetch (git-lfs 3.7.1 command_fetch.go)", .timeLimit(.minutes(2)))
struct LFSFetchTests {
    let old = Data("old contents\n".utf8)
    let new = Data("new contents\n".utf8)
    let other = Data("other branch\n".utf8)

    func oid(_ data: Data) -> String { LFSServerRepository.oid(data) }

    func gets(_ server: LFSTestServer) -> [String] {
        server.requests().filter { $0.method == "GET" }.map(\.path)
    }

    /// `old` behind HEAD, `new` at the tip of main, `other` only on branch `other`.
    func history(_ repo: LFSServerRepository) async throws {
        try await repo.commit([("a.dat", old)], message: "old")
        try await repo.git.checkoutNewBranch(name: "other")
        try await repo.commit([("b.dat", other)], message: "other")
        try await repo.git.checkout(ref: "main")
        try await repo.commit([("a.dat", new)], message: "new")
    }

    @Test("without --all only the tip tree of the current ref is fetched")
    func tipOnly() async throws {
        try await LFSTestServer.withServer { server in
            for data in [old, new, other] { server.store(data, oid: oid(data)) }
            try await LFSServerRepository.run(server) { repo in
                try await history(repo)
                let result = try await repo.fetch(git: repo.git)
                #expect(result.status == 0)
                #expect(result.stderr == "Fetching reference refs/heads/main\n")
                #expect(result.stdout == "")
                #expect(gets(server) == ["/objects/\(oid(new))"])
                #expect(repo.hasLocally(new))
                #expect(!repo.hasLocally(old))
            }
        }
    }

    @Test("--all fetches every object in history and logs the object count")
    func all() async throws {
        try await LFSTestServer.withServer { server in
            for data in [old, new, other] { server.store(data, oid: oid(data)) }
            try await LFSServerRepository.run(server) { repo in
                try await history(repo)
                let result = try await repo.fetch(all: true, git: repo.git)
                #expect(result.status == 0)
                #expect(result.stderr == "Fetching all references...\n")
                #expect(result.stdout == "3 objects found, done.\n")
                #expect(Set(gets(server)) == Set([old, new, other].map { "/objects/\(oid($0))" }))
            }
        }
    }

    @Test("--all with refs scans only their history, without the banner")
    func allWithRefs() async throws {
        try await LFSTestServer.withServer { server in
            for data in [old, new, other] { server.store(data, oid: oid(data)) }
            try await LFSServerRepository.run(server) { repo in
                try await history(repo)
                let result = try await repo.fetch(refs: ["refs/heads/main"], all: true, git: repo.git)
                #expect(result.status == 0)
                #expect(result.stderr == "")
                #expect(result.stdout == "2 objects found, done.\n")
                #expect(Set(gets(server)) == Set([old, new].map { "/objects/\(oid($0))" }))
            }
        }
    }

    @Test("--all refuses an explicit include or exclude")
    func allWithInclude() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                try await history(repo)
                let result = try await repo.fetch(include: "a.dat", all: true, git: repo.git)
                #expect(result.status == 2)
                #expect(result.stderr == "Cannot combine --all with --include or --exclude\n")
                #expect(server.requests().isEmpty)
            }
        }
    }

    @Test("--all says it ignores lfs.fetchinclude")
    func allIgnoresConfig() async throws {
        try await LFSTestServer.withServer { server in
            for data in [old, new, other] { server.store(data, oid: oid(data)) }
            try await LFSServerRepository.run(server, config: [("lfs.fetchinclude", "nothing")]) { repo in
                try await history(repo)
                let result = try await repo.fetch(all: true, git: repo.git)
                #expect(result.stderr == """
                Ignoring global include / exclude paths to fulfil --all
                Fetching all references...

                """)
                #expect(gets(server).count == 3)
            }
        }
    }

    @Test("an explicit include replaces lfs.fetchinclude, while lfs.fetchexclude still applies")
    func includeExclude() async throws {
        let a = Data("a\n".utf8), b = Data("b\n".utf8), c = Data("c\n".utf8)
        try await LFSTestServer.withServer { server in
            for data in [a, b, c] { server.store(data, oid: oid(data)) }
            let config = [("lfs.fetchinclude", "dir"), ("lfs.fetchexclude", "dir/c.dat")]
            try await LFSServerRepository.run(server, config: config) { repo in
                try await repo.commit([("a.dat", a), ("dir/b.dat", b), ("dir/c.dat", c)])
                _ = try await repo.fetch(git: repo.git)
                #expect(gets(server) == ["/objects/\(oid(b))"])

                _ = try await repo.fetch(include: "a.dat, dir/", git: repo.git)
                #expect(gets(server) == ["/objects/\(oid(b))", "/objects/\(oid(a))"])

                _ = try await repo.fetch(exclude: "", git: repo.git)
                #expect(gets(server).last == "/objects/\(oid(c))")
                #expect(gets(server).count == 3)
            }
        }
    }

    @Test("objects already in the store are not batched")
    func alreadyLocal() async throws {
        try await LFSTestServer.withServer { server in
            server.store(new, oid: oid(new))
            try await LFSServerRepository.run(server) { repo in
                try await repo.commit([("a.dat", new)])
                try await repo.storeLocally(new)
                let result = try await repo.fetch(git: repo.git)
                #expect(result.status == 0)
                #expect(server.requests().isEmpty)
            }
        }
    }

    @Test("--dry-run batches but transfers nothing, printing each object once")
    func dryRun() async throws {
        try await LFSTestServer.withServer { server in
            server.store(new, oid: oid(new))
            try await LFSServerRepository.run(server) { repo in
                try await repo.commit([("a.dat", new)])
                let result = try await repo.fetch(
                    refs: ["refs/heads/main", "refs/heads/main"], dryRun: true, git: repo.git)
                #expect(result.status == 0)
                #expect(result.stderr == """
                Fetching reference refs/heads/main
                fetch \(oid(new)) => a.dat
                Fetching reference refs/heads/main

                """)
                #expect(result.stdout == "")
                #expect(server.requests().map(\.method) == ["POST"])
                #expect(server.requests().map(\.path) == ["/objects/batch"])
                #expect(!repo.hasLocally(new))
            }
        }
    }

    @Test("--json lists the transferred objects, then an empty list once they are local")
    func json() async throws {
        try await LFSTestServer.withServer { server in
            server.store(new, oid: oid(new))
            try await LFSServerRepository.run(server) { repo in
                try await repo.commit([("a.dat", new)])
                let dry = try await repo.fetch(dryRun: true, json: true, git: repo.git)
                let result = try await repo.fetch(json: true, git: repo.git)
                #expect(result.status == 0)
                #expect(repo.hasLocally(new))
                let path = try await LocalStore.open(repo.git).objectPathname(oid(new)).path
                let expected = """
                {
                 "transfers": [
                  {
                   "name": "a.dat",
                   "oid": "\(oid(new))",
                   "size": \(new.count),
                   "actions": {
                    "download": {
                     "href": "\(server.endpoint.absoluteString)/objects/\(oid(new))",
                     "expires_at": "EXPIRES"
                    }
                   },
                   "path": "\(path)"
                  }
                 ]
                }

                """
                #expect(Self.redactingExpiry(dry.stdout) == expected)
                #expect(Self.redactingExpiry(result.stdout) == expected)

                let again = try await repo.fetch(json: true, git: repo.git)
                #expect(again.stdout == "{\n \"transfers\": []\n}\n")
            }
        }
    }

    @Test("a failed object is reported and the fetch fails with the endpoint")
    func failure() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                try await repo.commit([("a.dat", new)])
                let result = try await repo.fetch(json: true, git: repo.git)
                #expect(result.status == 2)
                #expect(result.stdout == "")
                #expect(result.stderr == """
                Fetching reference refs/heads/main
                [\(oid(new))] Object does not exist: [404] Object does not exist
                error: failed to fetch some objects from '\(server.endpoint.absoluteString)'

                """)
            }
        }
    }

    @Test("with forced progress the meter logs to stdout and never says done")
    func forcedProgress() async throws {
        try await LFSTestServer.withServer { server in
            server.store(new, oid: oid(new))
            try await LFSServerRepository.run(server, config: [("lfs.forceprogress", "true")]) { repo in
                try await repo.commit([("a.dat", new)])
                let result = try await repo.fetch(git: repo.git)
                let line = "Downloading LFS objects: 100% (1/1), 13 B | 0 B/s"
                #expect(result.stdout.hasSuffix(line + String(repeating: " ", count: 80 - line.count) + "\r"))
                #expect(!result.stdout.contains("done."))
            }
        }
    }

    @Test("JSON syntax is found by byte, so a combining mark after a quote does not hide it")
    func indentCombiningMark() {
        let compact = "{\"transfers\":[{\"name\":\"\u{301},x\",\"size\":1}]}"
        #expect(JSONIndent.indent(compact, by: " ") == """
        {
         "transfers": [
          {
           "name": "\u{301},x",
           "size": 1
          }
         ]
        }
        """)
    }

    static func redactingExpiry(_ text: String) -> String {
        text.replacingOccurrences(
            of: #""expires_at": "[^"]*""#, with: #""expires_at": "EXPIRES""#, options: .regularExpression)
    }
}
