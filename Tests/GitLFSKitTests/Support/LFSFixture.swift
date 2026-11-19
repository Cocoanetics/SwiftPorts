import Foundation
import SwiftGit

/// A throwaway repository under an ``IsolatedLFSHost``, so endpoint tests
/// share one way of laying down remotes, git config and `.lfsconfig`.
enum LFSFixture {
    static func make(
        _ host: IsolatedLFSHost,
        _ name: String,
        remotes: [(name: String, url: String)] = [],
        config: [(key: String, value: String)] = [],
        lfsconfig: String? = nil,
        commit: Bool = false
    ) async throws -> (directory: URL, client: GitClient) {
        let directory = host.root.appendingPathComponent(IsolatedLFSHost.shortName(name), isDirectory: true)
        let client = GitClient(workingDirectory: directory)
        try await client.initRepository(initialBranch: "main")
        try await client.configSet("user.email", "test@example.com")
        try await client.configSet("user.name", "Test")
        if commit {
            try Data("hi\n".utf8).write(to: directory.appendingPathComponent("README.md"))
            try await client.add(paths: ["README.md"])
            _ = try await client.commit(message: "init", author: nil, allowEmpty: false)
        }
        // `configSet` writes the repository config. `addRemote` under
        // `GIT_CONFIG_GLOBAL` writes the shared global file, so a second
        // repository in the same host is told origin already exists.
        for remote in remotes {
            try await client.configSet("remote.\(remote.name).url", remote.url)
        }
        for entry in config {
            try await client.configSet(entry.key, entry.value)
        }
        if let lfsconfig {
            try Data(lfsconfig.utf8).write(to: directory.appendingPathComponent(".lfsconfig"))
        }
        return (directory, client)
    }
}
