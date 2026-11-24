#if os(macOS) || os(Linux)
import CGitKit
import CLibgit2Shim
import Foundation
import GitKit
import ShellKit
import Testing
@testable import SwiftGit

/// `runIsolated` puts libgit2's process-global options back when it ends,
/// so a call made between runs sees the host's, not the last run's (#288).
@Suite("libgit2 options restored after a run", .serialized)
struct Libgit2SandboxingRestoreTests {
    private struct Options: Equatable {
        let global: String, xdg: String, system: String, homedir: String
    }

    private struct Failure: Error {}

    private static func searchPath(_ level: git_config_level_t) -> String {
        var buffer = [CChar](repeating: 0, count: 65_536)
        #expect(swiftports_libgit2_get_search_path(Int32(level.rawValue), &buffer, buffer.count) == 0)
        return String(cString: buffer)
    }

    private static func homedir() -> String {
        var buffer = [CChar](repeating: 0, count: 65_536)
        #expect(swiftports_libgit2_get_homedir(&buffer, buffer.count) == 0)
        return String(cString: buffer)
    }

    /// libgit2's options now; call under the lock, or inside a run.
    private static func current() -> Options {
        Options(global: searchPath(GIT_CONFIG_LEVEL_GLOBAL), xdg: searchPath(GIT_CONFIG_LEVEL_XDG),
                system: searchPath(GIT_CONFIG_LEVEL_SYSTEM), homedir: homedir())
    }

    private static func locked() -> Options {
        Libgit2.ensureInitialized()
        return Libgit2Sandboxing.shared.withOptionsLock { current() }
    }

    private static func temporaryDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func shell(_ variables: [String: String], in directory: URL) -> Shell {
        Shell(environment: Environment(variables: variables, workingDirectory: directory.path))
    }

    @Test func homeRunRestoresOptions() async throws {
        let home = try Self.temporaryDirectory("RestoreHome")
        defer { try? FileManager.default.removeItem(at: home) }
        let before = Self.locked()
        try await Self.shell(["HOME": home.path], in: home).withCurrent {
            try Libgit2Sandboxing.shared.runIsolated(nil) {
                #expect(Self.searchPath(GIT_CONFIG_LEVEL_GLOBAL) == home.path)
                #expect(Self.homedir() == home.path)
                #expect(Libgit2Sandboxing.shared.globalHome == home.path)
            }
        }
        #expect(Self.locked() == before)
        #expect(Libgit2Sandboxing.shared.globalHome == NSHomeDirectory())
    }

    @Test func globalOverrideRunRestoresOptions() async throws {
        let home = try Self.temporaryDirectory("RestoreGlobal")
        defer { try? FileManager.default.removeItem(at: home) }
        try "[a]\n\tb = c\n".write(to: home.appendingPathComponent("named.cfg"), atomically: true, encoding: .utf8)
        let before = Self.locked()
        try await Self.shell(["HOME": "/elsewhere", "GIT_CONFIG_GLOBAL": home.path + "/named.cfg"], in: home)
            .withCurrent {
                let client = GitClient(workingDirectory: home)
                try await client.isolatedGated {
                    #expect(Self.searchPath(GIT_CONFIG_LEVEL_GLOBAL).isEmpty)
                    #expect(Self.searchPath(GIT_CONFIG_LEVEL_XDG).isEmpty)
                    #expect(Libgit2Sandboxing.shared.environment.globalOverride)
                }
            }
        #expect(Self.locked() == before)
        #expect(Libgit2Sandboxing.shared.environment == .none)
    }

    @Test func sandboxedRunRestoresSystem() async throws {
        let root = try Self.temporaryDirectory("RestoreSystem")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = Self.locked()
        Libgit2Sandboxing.shared.hostSystemSearchPath = root.path
        defer { Libgit2Sandboxing.shared.hostSystemSearchPath = nil }
        let sandboxed = Shell(environment: Environment(variables: ["HOME": root.path],
                                                       workingDirectory: root.path),
                              sandbox: Sandbox.rooted(at: root))
        try await sandboxed.withCurrent {
            try Libgit2Sandboxing.shared.runIsolated(Shell.current.sandbox) {
                #expect(Self.searchPath(GIT_CONFIG_LEVEL_SYSTEM).isEmpty)
            }
        }
        #expect(Self.locked() == before)
        try await sandboxed.withCurrent {
            try GitSandboxPolicy.$allowsHostSystemConfig.withValue(true) {
                try Libgit2Sandboxing.shared.runIsolated(Shell.current.sandbox) {
                    #expect(Self.searchPath(GIT_CONFIG_LEVEL_SYSTEM) == root.path)
                }
            }
        }
        #expect(Self.locked() == before)
    }

    @Test func throwingBodyRestores() async throws {
        let home = try Self.temporaryDirectory("RestoreThrow")
        defer { try? FileManager.default.removeItem(at: home) }
        let before = Self.locked()
        await #expect(throws: Failure.self) {
            try await Self.shell(["HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1"], in: home).withCurrent {
                try Libgit2Sandboxing.shared.runIsolated(nil) {
                    #expect(Self.searchPath(GIT_CONFIG_LEVEL_SYSTEM).isEmpty)
                    throw Failure()
                }
            }
        }
        #expect(Self.locked() == before)
    }

    @Test func unsetHomeRestoresHomedir() async throws {
        let directory = try Self.temporaryDirectory("RestoreNoHome")
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = Self.locked()
        try await Self.shell([:], in: directory).withCurrent {
            try Libgit2Sandboxing.shared.runIsolated(nil) {
                #expect(Self.searchPath(GIT_CONFIG_LEVEL_GLOBAL).isEmpty)
            }
        }
        let after = Self.locked()
        #expect(after == before)
        #expect(after.homedir == before.homedir)
    }

    /// libgit2's setter expands `$PATH`, so a default guessed from an
    /// `XDG_CONFIG_HOME` holding one literally comes back as the default.
    @Test func defaultWithLiteralPathMarkerRestores() async throws {
        let root = try Self.temporaryDirectory("RestorePathMarker")
        defer { try? FileManager.default.removeItem(at: root) }
        let xdgHome = root.path + "/x$PATHy"
        let xdg = Int32(GIT_CONFIG_LEVEL_XDG.rawValue)
        let saved = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let before: Options = Libgit2Sandboxing.shared.withOptionsLock {
            setenv("XDG_CONFIG_HOME", xdgHome, 1)
            #expect(swiftports_libgit2_set_search_path(xdg, nil) == 0)
            return Self.current()
        }
        defer {
            Libgit2Sandboxing.shared.withOptionsLock {
                if let saved { setenv("XDG_CONFIG_HOME", saved, 1) } else { unsetenv("XDG_CONFIG_HOME") }
                _ = swiftports_libgit2_set_search_path(xdg, nil)
            }
        }
        #expect(before.xdg == xdgHome + "/git")
        try await Self.shell(["HOME": root.path], in: root).withCurrent {
            try Libgit2Sandboxing.shared.runIsolated(nil) {
                #expect(Self.searchPath(GIT_CONFIG_LEVEL_XDG) == root.path + "/.config/git")
            }
        }
        #expect(Self.locked() == before)
    }

    /// The regression the issue reports: a plain libgit2 open after a run
    /// that pointed `HOME` elsewhere and named `GIT_CONFIG_GLOBAL` reads the
    /// host's global config again.
    @Test func unscopedOpenSeesHostConfigAfterRun() async throws {
        let root = try Self.temporaryDirectory("RestoreUnscoped")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("host"), repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        try "[test]\n\tmarker = host\n".write(
            to: host.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        try "[test]\n\tmarker = named\n".write(
            to: root.appendingPathComponent("named.cfg"), atomically: true, encoding: .utf8)
        _ = try Repository.initialize(at: repo)

        // Stand in for the host's options: GLOBAL at the fixture's home.
        let original = Self.locked()
        Libgit2Sandboxing.shared.withOptionsLock {
            #expect(swiftports_libgit2_set_search_path(Int32(GIT_CONFIG_LEVEL_GLOBAL.rawValue), host.path) == 0)
        }
        defer {
            Libgit2Sandboxing.shared.withOptionsLock {
                _ = swiftports_libgit2_set_search_path(Int32(GIT_CONFIG_LEVEL_GLOBAL.rawValue), original.global)
            }
        }

        let inside = try await Self.shell(
            ["HOME": "/elsewhere", "GIT_CONFIG_GLOBAL": root.path + "/named.cfg"], in: repo).withCurrent {
                try await GitClient(workingDirectory: repo).configGet("test.marker")
            }
        #expect(inside == "named")

        let outside: String? = Libgit2Sandboxing.shared.withOptionsLock {
            var handle: OpaquePointer?
            var config: OpaquePointer?
            var value: UnsafePointer<CChar>?
            defer {
                git_config_free(config)
                git_repository_free(handle)
            }
            guard git_repository_open(&handle, repo.path) == 0,
                  git_repository_config_snapshot(&config, handle) == 0,
                  git_config_get_string(&value, config, "test.marker") == 0 else { return nil }
            return value.map { String(cString: $0) }
        }
        #expect(outside == "host")
    }

    /// Runs with their own `HOME` each see theirs, and readers that take the
    /// lock between them see the host's. A GitKit call that takes no lock at
    /// all can still see a run's options while it is in progress; with
    /// SwiftGit linked, such calls go through an operation.
    @Test func concurrentRunsLeaveHostOptions() async throws {
        let root = try Self.temporaryDirectory("RestoreConcurrent")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = Self.locked()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                let home = root.appendingPathComponent("home\(index)").path
                group.addTask {
                    try await Self.shell(["HOME": home], in: root).withCurrent {
                        try Libgit2Sandboxing.shared.runIsolated(nil) {
                            #expect(Self.searchPath(GIT_CONFIG_LEVEL_GLOBAL) == home)
                            #expect(Self.homedir() == home)
                        }
                    }
                }
                group.addTask { #expect(Self.locked() == before) }
            }
            try await group.waitForAll()
        }
        #expect(Self.locked() == before)
    }
}
#endif
