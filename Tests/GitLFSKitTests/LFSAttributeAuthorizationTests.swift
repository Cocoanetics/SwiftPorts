import Foundation
import Testing
import ShellKit
@testable import SwiftGit
@testable import GitLFSKit

extension LFSFilterTests {
    @Suite("Attribute sources are authorized before libgit2 evaluation")
    struct LFSAttributeAuthorizationTests {
        @Test(arguments: ["absolute", "home", "relative"])
        func configuredAttributes(_ location: String) async throws {
            try await LFSFilterFixture.run { host in
                let made = try await LFSFilterFixture.seed(host, data: Data("attrs\n".utf8))
                let file: URL
                let configured: String
                switch location {
                case "home":
                    file = host.home.appendingPathComponent("attributes")
                    configured = "~/attributes"
                case "relative":
                    let root = try #require(try await made.client.toplevel())
                    file = URL(fileURLWithPath: root, isDirectory: true)
                        .appendingPathComponent("attributes", isDirectory: false)
                    configured = "attributes"
                default:
                    file = host.root.appendingPathComponent("attributes")
                    configured = file.path
                }
                try Data("*.bin filter=lfs\n".utf8).write(to: file)
                try await made.client.configSet("core.attributesfile", configured, scope: .local)
                #expect(try await made.client.filterAttribute(for: ["x.bin"])["x.bin"] == "lfs")
                try await expectDenied(file, host: host, client: made.client)
                // Absent candidates must be authorized before any existence probe, too.
                try FileManager.default.removeItem(at: file)
                try await expectDenied(file, host: host, client: made.client)
            }
        }

        @Test(arguments: [false, true])
        func defaultGlobalAttributes(_ explicitXDG: Bool) async throws {
            try await LFSFilterFixture.run { host in
                let made = try await LFSFilterFixture.seed(host, data: Data("attrs\n".utf8))
                Shell.current.environment["GIT_CONFIG_GLOBAL"] = nil
                if !explicitXDG { Shell.current.environment["XDG_CONFIG_HOME"] = nil }
                let base = explicitXDG ? host.xdgConfigHome : host.home.appendingPathComponent(".config")
                let directory = base.appendingPathComponent("git")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("attributes")
                try Data("*.bin filter=lfs\n".utf8).write(to: file)
                #expect(try await made.client.filterAttribute(for: ["x.bin"])["x.bin"] == "lfs")
                try await expectDenied(file, host: host, client: made.client)
                try FileManager.default.removeItem(at: file)
                try await expectDenied(file, host: host, client: made.client)
            }
        }

        @Test("absent info and nested worktree attributes are authorized")
        func absentLocalAttributes() async throws {
            try await LFSFilterFixture.run { host in
                let made = try await LFSFilterFixture.seed(host, data: Data("attrs\n".utf8))
                let root = try #require(try await made.client.toplevel())
                for relative in [".git/info/attributes", "nested/.gitattributes"] {
                    let file = URL(fileURLWithPath: root, isDirectory: true)
                        .appendingPathComponent(relative, isDirectory: false)
                    #expect(!FileManager.default.fileExists(atPath: file.path))
                    Shell.current.sandbox = host.sandbox(refusing: {
                        $0.standardizedFileURL.path == file.standardizedFileURL.path
                    })
                    await #expect(throws: Sandbox.Denial.self) {
                        _ = try await made.client.filterAttribute(for: ["nested/x.bin"])
                    }
                    Shell.current.sandbox = host.sandbox
                }
            }
        }

        @Test("the index and queried worktree file are authorized before attribute evaluation")
        func attributeInputs() async throws {
            try await LFSFilterFixture.run { host in
                let made = try await LFSFilterFixture.seed(host, data: Data("attrs\n".utf8))
                for relative in [".git/index", "a.lfs", ".gitattributes"] {
                    let file = made.directory.appendingPathComponent(relative)
                    try await expectDenied(file, host: host, client: made.client, path: "a.lfs")
                }
            }
        }

        @Test("linked worktrees authorize the shared info/attributes file")
        func linkedWorktreeAttributes() async throws {
            try await LFSFilterFixture.run { host in
                let made = try await LFSFilterFixture.seed(host, data: Data("attrs\n".utf8))
                let linked = host.root.appendingPathComponent("linked")
                try await made.client.worktreeAdd(path: linked, branch: "linked")
                let client = SwiftGit.GitClient(workingDirectory: linked)
                let file = made.directory.appendingPathComponent(".git/info/attributes")
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("*.bin filter=lfs\n".utf8).write(to: file)
                #expect(try await client.filterAttribute(for: ["x.bin"])["x.bin"] == "lfs")
                try await expectDenied(file, host: host, client: client)
            }
        }

        @Test("system attributes and macro preloads require authorization, including with NOSYSTEM")
        func systemAttributes() async throws {
            try await LFSFilterFixture.run { host in
                let made = try await LFSFilterFixture.seed(host, data: Data("attrs\n".utf8))
                let system = host.root.appendingPathComponent("etc")
                try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
                let file = system.appendingPathComponent("gitattributes")
                try Data("*.bin filter=lfs\n".utf8).write(to: file)
                Libgit2Sandboxing.shared.hostSystemSearchPath = system.path
                defer { Libgit2Sandboxing.shared.hostSystemSearchPath = nil }
                Shell.current.environment["GIT_CONFIG_NOSYSTEM"] = nil
                try await GitSandboxPolicy.$allowsHostSystemConfig.withValue(true) {
                    #expect(try await made.client.filterAttribute(for: ["x.bin"])["x.bin"] == "lfs")
                    try await expectDenied(file, host: host, client: made.client)
                    Shell.current.environment["GIT_ATTR_NOSYSTEM"] = "1"
                    try await expectDenied(file, host: host, client: made.client)
                }
            }
        }

        private func expectDenied(
            _ file: URL, host: IsolatedLFSHost, client: SwiftGit.GitClient, path: String = "x.bin"
        ) async throws {
            Shell.current.sandbox = host.sandbox(refusing: {
                $0.standardizedFileURL.path == file.standardizedFileURL.path
            })
            defer { Shell.current.sandbox = host.sandbox }
            await #expect(throws: Sandbox.Denial.self) {
                _ = try await client.filterAttribute(for: [path])
            }
        }
    }
}
