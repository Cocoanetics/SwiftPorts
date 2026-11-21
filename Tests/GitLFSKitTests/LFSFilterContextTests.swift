import Foundation
import Testing
import ShellKit
import SwiftGit
@testable import GitLFSKit

extension LFSFilterTests {
    @Suite("LFS filter configuration")
    struct LFSFilterContextTests {
        @Test("required alone never activates a direction; non-empty process takes precedence")
        func commands() async throws {
            try await LFSStreamFixture.run { _, git, _ in
                try await git.configSet("filter.lfs.required", "true")
                for direction in [GitFilterDirection.clean, .smudge] {
                    let key = direction == .clean ? "clean" : "smudge"
                    #expect(try await LFSFilterContext.command(git, direction: direction) == nil)
                    try await git.configSet("filter.lfs.\(key)", "git-lfs \(key) --skip")
                    try await git.configSet("filter.lfs.process", "")
                    #expect(try await LFSFilterContext.command(git, direction: direction) == "git-lfs \(key) --skip")
                    try await git.configSet("filter.lfs.process", "git-lfs filter-process")
                    let context = try #require(try await LFSFilterContext.load(
                        git, direction: direction, remotes: LFSFilterRemotes()))
                    #expect(context.required)
                    #expect(!context.skipSmudge)
                    _ = try await git.configUnset("filter.lfs.process")
                    _ = try await git.configUnset("filter.lfs.\(key)")
                }
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
