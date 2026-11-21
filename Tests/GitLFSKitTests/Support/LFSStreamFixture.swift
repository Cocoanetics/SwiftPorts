import Foundation
import ShellKit
import SwiftGit
@testable import GitLFSKit

enum LFSStreamFixture {
    static func run(
        config: [(key: String, value: String)] = [], required: Bool = true, skip: Bool = false,
        endpoint: String? = "https://stream.example/repo.git/info/lfs",
        refusing: @escaping @Sendable (URL) -> Bool = { _ in false },
        _ body: (LFSFilterContext, SwiftGit.GitClient, URL) async throws -> Void
    ) async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let endpoints = endpoint.map { [("lfs.url", $0)] } ?? []
            let made = try await LFSFixture.make(host, "streams", config:
                endpoints + [("lfs.transfer.maxretries", "1")] + config, commit: true)
            let client = await LFSClient(git: made.client, configuration: LFSStreamURLProtocol.configuration)
            let context = try await LFSFilterContext(
                client: client, store: LocalStore.open(made.client), required: required,
                skipSmudge: skip, shell: Shell.current, remotes: LFSFilterRemotes())
            Shell.current.sandbox = host.sandbox(refusing: refusing)
            try await body(context, made.client, made.directory)
        }
    }
}
