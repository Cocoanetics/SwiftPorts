import Foundation
import Crypto
import Testing
import ShellKit
import SwiftGit
@testable import GitLFSKit

enum LFSFilterFixture {
    static let commands: [(key: String, value: String)] = [
        ("filter.lfs.process", "git-lfs filter-process"),
        ("filter.lfs.clean", "git-lfs clean -- %f"),
        ("filter.lfs.smudge", "git-lfs smudge -- %f"),
        ("filter.lfs.required", "true")
    ]

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func run(_ body: (IsolatedLFSHost) async throws -> Void) async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        try GitLFSKit.installFilter()
        defer { try? GitLFSKit.uninstallFilter() }
        try await host.run { try await body(host) }
    }

    static func seed(
        _ host: IsolatedLFSHost, data: Data,
        config: [(key: String, value: String)] = []
    ) async throws -> (directory: URL, client: SwiftGit.GitClient, pointer: Pointer) {
        let made = try await LFSFixture.make(host, "source", config: commands + config)
        try Data("*.lfs filter=lfs -text\n".utf8)
            .write(to: made.directory.appendingPathComponent(".gitattributes"))
        try data.write(to: made.directory.appendingPathComponent("a.lfs"))
        try await made.client.add(paths: [".gitattributes", "a.lfs"])
        _ = try await made.client.commit(message: "LFS content", author: nil, allowEmpty: false)
        return (made.directory, made.client, Pointer(oid: hash(data), size: Int64(data.count)))
    }

    static func restore(_ git: SwiftGit.GitClient, directory: URL, expected: Data) async throws {
        let file = directory.appendingPathComponent("a.lfs")
        try FileManager.default.removeItem(at: file)
        try await git.checkoutPaths(["a.lfs"])
        #expect(try Data(contentsOf: file) == expected)
        #expect(try await git.status().isClean)
    }

    /// Clone must see configuration before checkout creates its first file.
    static func configureClone(_ config: [(key: String, value: String)]) {
        let values = commands + config
        Shell.current.environment["GIT_CONFIG_COUNT"] = String(values.count)
        for (index, entry) in values.enumerated() {
            Shell.current.environment["GIT_CONFIG_KEY_\(index)"] = entry.key
            Shell.current.environment["GIT_CONFIG_VALUE_\(index)"] = entry.value
        }
    }
}
