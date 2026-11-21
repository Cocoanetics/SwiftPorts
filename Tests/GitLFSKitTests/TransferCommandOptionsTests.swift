import Foundation
import GitLFSTestSupport
import ShellKit
import Testing
@testable import GitLFSKit

@Suite("LFS transfer command options")
struct TransferCommandOptionsTests {
    let first = Data("first object\n".utf8)
    let second = Data("second object\n".utf8)

    private func input(_ text: String) -> Shell {
        let shell = Shell(stdin: .data(Data(text.utf8)), environment: Shell.current.environment)
        shell.sandbox = Shell.current.sandbox
        return shell
    }

    @Test func fetchDefaultAndExplicitRefs() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                let oid = LFSServerRepository.oid(first)
                server.store(first, oid: oid)
                try await repo.commit([("a.bin", first)])
                var options = FetchOptions()
                options.json = true
                let result = try await options.run([], client: repo.client, git: repo.git)
                #expect(result.status == 0 && repo.hasLocally(first))
                #expect(result.stderr == "Fetching reference refs/heads/main\n")
                #expect(result.stdout.contains("\"oid\": \"\(oid)\""))
                let explicit = try await options.run(["origin", "main"], client: repo.client, git: repo.git)
                #expect(explicit.status == 0 && explicit.stderr == result.stderr)
                #expect(explicit.stdout == "{\n \"transfers\": []\n}\n")
            }
        }
    }

    @Test func pushRangeAllAndStdin() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                let one = try await repo.commit([("a.bin", first)])
                try await repo.commit([("b.bin", second)])
                try await repo.setReference("refs/remotes/origin/main", to: one)
                var options = PushOptions()
                options.dryRun = true
                let ranged = try await options.run(["origin", "main"], client: repo.client, git: repo.git)
                #expect(ranged.status == 0)
                #expect(!ranged.stdout.contains(LFSServerRepository.oid(first)))
                #expect(ranged.stdout.contains(LFSServerRepository.oid(second)))
                options.all = true
                let all = try await options.run(["origin"], client: repo.client, git: repo.git)
                #expect(all.status == 0 && all.stdout.contains(LFSServerRepository.oid(first)))
                #expect(all.stdout.contains(LFSServerRepository.oid(second)))
                options.all = false
                options.stdin = true
                let streamed = try await input("main\r\n\nmain\n").withCurrent {
                    try await options.run(["origin"], client: repo.client, git: repo.git)
                }
                #expect(streamed.status == 0 && streamed.stdout == ranged.stdout)
                #expect(server.requests().isEmpty)
            }
        }
    }

    @Test func pushStoredOIDsWithoutRefs() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                try await repo.storeLocally(first)
                let oid = LFSServerRepository.oid(first)
                var options = PushOptions()
                options.objectID = true
                options.stdin = true
                let uploaded = try await input("\(oid)\n\n").withCurrent {
                    try await options.run(["origin"], client: repo.client, git: repo.git)
                }
                #expect(uploaded.status == 0 && server.bytes(for: oid) == first)
                #expect(server.requests().contains { $0.method == "PUT" })
            }
        }
    }

    @Test func prePushFourFieldsAndDeletion() async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                let one = try await repo.commit([("a.bin", first)])
                let two = try await repo.commit([("b.bin", second)])
                let zero = String(repeating: "0", count: 40)
                let lines = "\nrefs/heads/gone \(zero) refs/heads/gone \(one)\n"
                    + "refs/heads/main \(two) refs/heads/main \(one)\n"
                var options = PrePushOptions()
                options.dryRun = true
                let result = try await input(lines).withCurrent {
                    try await options.run(["origin", "ignored-url"], client: repo.client, git: repo.git)
                }
                #expect(result.status == 0)
                #expect(!result.stdout.contains(LFSServerRepository.oid(first)))
                #expect(result.stdout == "push \(LFSServerRepository.oid(second)) => b.bin\n")
                #expect(server.requests().isEmpty)
            }
        }
    }
}
