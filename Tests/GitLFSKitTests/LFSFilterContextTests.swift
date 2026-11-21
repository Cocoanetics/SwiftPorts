import Foundation
import Testing
import ShellKit
import SwiftGit
@testable import GitLFSKit

extension LFSFilterTests {
    @Suite("LFS filter configuration")
    struct LFSFilterContextTests {
        @Test("process presence takes precedence, including an empty required command")
        func commands() async throws {
            try await LFSStreamFixture.run { _, git, _ in
                try await git.configSet("filter.lfs.required", "true")
                for direction in [GitFilterDirection.clean, .smudge] {
                    let key = direction == .clean ? "clean" : "smudge"
                    #expect(try await LFSFilterContext.command(git, direction: direction) == nil)
                    try await git.configSet("filter.lfs.\(key)", "git-lfs \(key) --skip")
                    #expect(try await LFSFilterContext.command(git, direction: direction) == "git-lfs \(key) --skip")
                    try await git.configSet("filter.lfs.process", "")
                    #expect(try await LFSFilterContext.command(git, direction: direction) == nil)
                    await #expect(throws: LFSClientError.self) {
                        try await LFSFilterContext.load(git, direction: direction, remotes: LFSFilterRemotes())
                    }
                    try await git.configSet("filter.lfs.process", "git-lfs filter-process")
                    let context = try #require(try await LFSFilterContext.load(
                        git, direction: direction, remotes: LFSFilterRemotes()))
                    #expect(context.required)
                    #expect(!context.skipSmudge)
                    _ = try await git.configUnset("filter.lfs.process")
                    #expect(try await LFSFilterContext.command(git, direction: direction) == "git-lfs \(key) --skip")
                    _ = try await git.configUnset("filter.lfs.\(key)")
                }
            }
        }

        @Test("empty process bypasses optional commands and fails required commands without accessing the store",
               arguments: [false, true])
        func emptyProcess(required: Bool) async throws {
            try await LFSStreamFixture.run(config: [
                ("filter.lfs.clean", "git-lfs clean -- %f"),
                ("filter.lfs.smudge", "git-lfs smudge -- %f"),
                ("filter.lfs.process", ""), ("filter.lfs.required", required ? "true" : "false")
            ]) { context, git, directory in
                try GitLFSKit.installFilter()
                defer { try? GitLFSKit.uninstallFilter() }
                let file = directory.appendingPathComponent("a.lfs")
                let content = Data("content must not be cleaned\n".utf8)
                try Data("*.lfs filter=lfs -text\n".utf8)
                    .write(to: directory.appendingPathComponent(".gitattributes"))
                try content.write(to: file)
                if required {
                    await #expect(throws: GitFilterError.self) { try await git.add(paths: ["a.lfs"]) }
                    #expect(!FileManager.default.fileExists(atPath: context.store.storageDirectory.path))
                    return
                }
                try await git.add(paths: [".gitattributes", "a.lfs"])
                let entry = try #require(try await git.indexedEntries().first { $0.path == "a.lfs" })
                #expect(try await git.catFileBlob(entry.oid) == content)
                let pointer = Data(Pointer(oid: String(repeating: "a", count: 64), size: 100).encoded.utf8)
                try pointer.write(to: file)
                try await git.add(paths: ["a.lfs"])
                _ = try await git.commit(message: "pointer", author: nil, allowEmpty: false)
                try FileManager.default.removeItem(at: file)
                try await git.checkoutPaths(["a.lfs"])
                #expect(try Data(contentsOf: file) == pointer)
                #expect(!FileManager.default.fileExists(atPath: context.store.storageDirectory.path))
            }
        }

        @Test("install --skip-smudge and Shell environment booleans",
               arguments: ["", "true", "1", "on", "yes", "false", "0"])
        func skip(value: String) async throws {
            try await LFSStreamFixture.run { _, git, _ in
                Shell.current.environment["GIT_LFS_SKIP_SMUDGE"] = value
                var options = FilterOptions()
                options.local = true
                options.skipRepo = true
                options.skipSmudge = true
                _ = try await options.install(git)
                var context = try #require(try await LFSFilterContext.load(
                    git, direction: .smudge, remotes: LFSFilterRemotes()))
                #expect(context.skipSmudge)
                try await git.configSet("filter.lfs.process", "git-lfs filter-process")
                context = try #require(try await LFSFilterContext.load(
                    git, direction: .smudge, remotes: LFSFilterRemotes()))
                #expect(context.skipSmudge == ["true", "1", "on", "yes"].contains(value))
            }
        }

        @Test("remote ref follows push.default and tracking branch")
        func ref() async throws {
            try await LFSStreamFixture.run(config: [
                ("branch.main.remote", "upstream"), ("branch.main.merge", "refs/heads/trunk")
            ]) { context, _, _ in
                #expect(context.refName == "refs/heads/trunk")
                #expect(await context.client.finder.downloadRemote() == "upstream")
            }
        }
    }
}
