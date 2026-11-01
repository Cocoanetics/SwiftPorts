#if os(macOS) || os(Linux)
import CLibgit2Shim
import Foundation
import GitKit
import ShellKit
import Testing
@testable import SwiftGit

@Suite("sandbox system gitconfig policy", .serialized)
struct SandboxSystemConfigPolicyTests {
    private struct Fixture {
        let root: URL, repo: URL, home: URL, system: URL
    }

    private static let key = "sandboxpolicy.sentinel"

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandboxSystemPolicy-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("repo"), home = root.appendingPathComponent("home")
        let system = root.appendingPathComponent("etc")
        for dir in [repo, home, system] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "[sandboxpolicy]\n\tsentinel = host\n".write(
            to: system.appendingPathComponent("gitconfig"), atomically: true, encoding: .utf8)
        Libgit2.ensureInitialized()
        var handle: OpaquePointer?
        #expect(git_repository_init(&handle, repo.path, 0) == 0)
        git_repository_free(handle)
        return Fixture(root: root, repo: repo, home: home, system: system)
    }

    private func shell(_ fixture: Fixture, inRepository: Bool = true,
                       environment: [String: String] = [:]) -> Shell {
        var env = Environment()
        env.variables = ["HOME": fixture.home.path].merging(environment) { $1 }
        // The sandbox root holds repo, home and the plain directory.
        if !inRepository {
            try? FileManager.default.createDirectory(
                at: fixture.root.appendingPathComponent("outside"), withIntermediateDirectories: true)
        }
        return Shell(environment: env, sandbox: Sandbox.rooted(at: fixture.root))
    }

    /// Reads the sentinel through `GitClient`, under the fixture's system search path.
    private func read(_ fixture: Fixture, inRepository: Bool, allow: Bool = false,
                      environment: [String: String] = [:]) async throws -> String? {
        let shell = shell(fixture, inRepository: inRepository, environment: environment)
        let directory = inRepository ? fixture.repo : fixture.root.appendingPathComponent("outside")
        Libgit2Sandboxing.shared.hostSystemSearchPath = fixture.system.path
        defer { Libgit2Sandboxing.shared.hostSystemSearchPath = nil }
        return try await shell.withCurrent {
            try await GitSandboxPolicy.$allowsHostSystemConfig.withValue(allow) {
                try await GitClient(workingDirectory: directory).configGet(Self.key)
            }
        }
    }

    private func effectiveSystemSearchPath() -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        #expect(swiftports_libgit2_get_search_path(Int32(2), &buffer, buffer.count) == 0)
        return String(cString: buffer)
    }

    @Test func sandboxDisablesSystemConfigByDefault() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(try await read(fixture, inRepository: true) == nil)
        #expect(try await read(fixture, inRepository: false) == nil)
        let shell = shell(fixture)
        try await shell.withCurrent {
            try Libgit2Sandboxing.shared.runIsolated(shell.sandbox) {
                #expect(effectiveSystemSearchPath().isEmpty)
            }
        }
    }

    @Test func explicitOptInExposesSystemConfig() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(try await read(fixture, inRepository: true, allow: true) == "host")
        #expect(try await read(fixture, inRepository: false, allow: true) == "host")
    }

    @Test func noSystemSuppressesEvenWhenOptedIn() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let env = ["GIT_CONFIG_NOSYSTEM": "1"]
        #expect(try await read(fixture, inRepository: true, allow: true, environment: env) == nil)
        #expect(try await read(fixture, inRepository: false, allow: true, environment: env) == nil)
    }

    @Test func transitionsRestoreTheIntendedState() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(try await read(fixture, inRepository: true, allow: true) == "host")
        #expect(try await read(fixture, inRepository: true) == nil)
        #expect(try await read(fixture, inRepository: true, allow: true) == "host")
        // Unsandboxed, libgit2's defaults return: the search path is not the sandbox's empty one.
        try Libgit2Sandboxing.shared.runIsolated(nil) {
            #expect(!effectiveSystemSearchPath().isEmpty)
        }
        #expect(try await read(fixture, inRepository: true) == nil)
    }

    @Test func explicitSystemScopeIsAuthorizedInSandbox() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shell = shell(fixture)
        Libgit2Sandboxing.shared.hostSystemSearchPath = fixture.system.path
        defer { Libgit2Sandboxing.shared.hostSystemSearchPath = nil }
        await #expect(throws: (any Error).self) {
            try await shell.withCurrent {
                _ = try await GitClient(workingDirectory: fixture.repo).configGet(Self.key, scope: .system)
            }
        }
    }

    @Test func namedSystemFileHonorsOptInForReads() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var env = Environment()
        env.variables = ["HOME": fixture.repo.path,
                         "GIT_CONFIG_SYSTEM": fixture.system.appendingPathComponent("gitconfig").path]
        // The named file is outside the sandbox root.
        let shell = Shell(environment: env, sandbox: Sandbox.rooted(at: fixture.repo))
        await #expect(throws: (any Error).self) {
            try await shell.withCurrent {
                _ = try await GitClient(workingDirectory: fixture.repo).configGet(Self.key, scope: .system)
            }
        }
        let value = try await shell.withCurrent {
            try await GitSandboxPolicy.$allowsHostSystemConfig.withValue(true) {
                try await GitClient(workingDirectory: fixture.repo).configGet(Self.key, scope: .system)
            }
        }
        #expect(value == "host")
        // Writes stay authorized.
        await #expect(throws: (any Error).self) {
            try await shell.withCurrent {
                try await GitSandboxPolicy.$allowsHostSystemConfig.withValue(true) {
                    try await GitClient(workingDirectory: fixture.repo).configSet(Self.key, "x", scope: .system)
                }
            }
        }
    }
}
#endif
