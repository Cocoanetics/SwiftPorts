import Foundation
import GitLFSTestSupport
import Testing
@_spi(GitLFSKit) import SwiftGit
@testable import GitLFSKit

extension TransferCommandOptionsTests {
    @Test("authenticated advertisements exclude only still-advertised tracking refs",
          arguments: [false, true], [false, true])
    func authenticatedStaleRef(_ prePush: Bool, _ urlScoped: Bool) async throws {
        try await LFSTestServer.withServer { server in
            try await LFSServerRepository.run(server) { repo in
                let base = try await repo.commit([("base.bin", first)])
                let tip = try await repo.commit([("new.bin", second)])
                try await repo.storeLocally(second)
                try await repo.setReference("refs/remotes/origin/main", to: base)
                try await repo.setReference("refs/remotes/origin/deleted", to: tip)
                let url = server.endpoint.absoluteString + "/repo.git"
                let authorization = "Bearer advertisement-secret"
                server.advertiseGitHead(base, authorization: authorization)
                try await repo.git.configSet("remote.origin.url", urlScoped ? "alias" : url)
                if urlScoped {
                    try await repo.git.configSet("url.\(url).insteadOf", "alias")
                    try await repo.git.configSet("http.extraHeader", "Authorization: wrong")
                }
                let key = urlScoped ? "http.\(url).extraHeader" : "http.extraHeader"
                try await repo.git.configSet(key, "Authorization: \(authorization)")
                let client = await LFSClient(git: repo.git, configuration: .ephemeral)
                let result: LFSCommandResult
                if prePush {
                    let line = "refs/heads/main \(tip) refs/heads/main \(base)\n"
                    result = try await input(line).withCurrent {
                        try await PrePushOptions().run(["origin", url], client: client, git: repo.git)
                    }
                } else {
                    result = try await PushOptions().run(["origin", "main"], client: client, git: repo.git)
                }
                #expect(result.status == 0, "\(result.stderr)")
                #expect(server.bytes(for: LFSServerRepository.oid(second)) == second)
                #expect(server.bytes(for: LFSServerRepository.oid(first)) == nil)
                let advertisement = try #require(server.requests().first { $0.path == "/repo.git/info/refs" })
                #expect(advertisement.status == 200)
                #expect(advertisement.requestHeaders["authorization"] == authorization)
            }
        }
    }
}
