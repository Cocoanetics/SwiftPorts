// GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM, GIT_CONFIG_NOSYSTEM, GIT_CONFIG_COUNT
// and the shell's HOME change what every git command reads, not only an
// explicit `git config --global`. Each case runs `git` here and the real
// /usr/bin/git on the same files, environment and working directory, and
// expects the same bytes.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ShellKit
import SwiftGit
@testable import GitCommand

@Suite("git config read from the environment")
struct GitCommandConfigEnvTests: ConfigTestHelpers {

    private static let realGit = "/usr/bin/git"
    private static var hasRealGit: Bool { FileManager.default.isExecutableFile(atPath: realGit) }

    /// What the real git printed and its exit status.
    private struct Real {
        let stdout: String, status: Int32
    }

    /// The real `git <args>` in `work` with the environment the shell
    /// under test has: HOME, no system config, plus `environment`.
    private func real(
        _ args: [String], home: URL, work: URL, environment: [String: String] = [:]
    ) throws -> Real {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.realGit)
        process.arguments = args
        process.currentDirectoryURL = work
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1"]
            .merging(environment) { $1 }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Real(stdout: String(decoding: data, as: UTF8.self), status: process.terminationStatus)
    }

    private func initRepository(_ work: URL, home: URL) throws {
        _ = try real(["init", "-q"], home: home, work: work)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `git <args>` under test, and the real one, for the same environment:
    /// both must print the same and exit alike.
    private func expectSame(
        _ args: [String], _ fixture: ConfigFixture, environment: [String: String] = [:],
        sandboxed: Bool = false, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let ours = try await git(
            args, root: fixture.root, home: fixture.home, work: fixture.work,
            environment: environment, sandboxed: sandboxed)
        let theirs = try real(args, home: fixture.home, work: fixture.work, environment: environment)
        #expect(ours.stdout == theirs.stdout, "git \(args.joined(separator: " ")) \(environment) sandboxed: \(sandboxed)",
                sourceLocation: sourceLocation)
        #expect(ours.status == theirs.status, "status of git \(args.joined(separator: " ")) \(environment)",
                sourceLocation: sourceLocation)
    }

    @Test("GIT_CONFIG_GLOBAL replaces ~/.gitconfig and the XDG file for every read, in and out of a repository")
    func globalFileReplacesHome() async throws {
        guard Self.hasRealGit else { return }
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try write("[user]\n\tname = Home\n[h]\n\tz = 1\n", to: fixture.home.appendingPathComponent(".gitconfig"))
        try write("[x]\n\tk = v\n", to: fixture.home.appendingPathComponent(".config/git/config"))
        let named = fixture.root.appendingPathComponent("named.cfg")
        try write("[user]\n\tname = Named\n[n]\n\tm = 2\n", to: named)

        // Outside a repository.
        for sandboxed in [false, true] {
            try await expectSame(["config", "--list"], fixture, sandboxed: sandboxed)
            try await expectSame(["config", "--list"], fixture, environment: ["GIT_CONFIG_GLOBAL": named.path],
                                 sandboxed: sandboxed)
            try await expectSame(["config", "user.name"], fixture, environment: ["GIT_CONFIG_GLOBAL": named.path],
                                 sandboxed: sandboxed)
            try await expectSame(["config", "h.z"], fixture, environment: ["GIT_CONFIG_GLOBAL": named.path],
                                 sandboxed: sandboxed)
        }

        // In a repository, whose own config is read too.
        try initRepository(fixture.work, home: fixture.home)
        for sandboxed in [false, true] {
            try await expectSame(["config", "--list"], fixture, sandboxed: sandboxed)
            try await expectSame(["config", "--list", "--show-origin"], fixture, sandboxed: sandboxed)
            try await expectSame(["config", "--list", "--show-origin"], fixture,
                                 environment: ["GIT_CONFIG_GLOBAL": named.path], sandboxed: sandboxed)
            try await expectSame(["config", "user.name"], fixture, environment: ["GIT_CONFIG_GLOBAL": named.path],
                                 sandboxed: sandboxed)
            try await expectSame(["config", "--get", "n.m"], fixture, environment: ["GIT_CONFIG_GLOBAL": named.path],
                                 sandboxed: sandboxed)
            try await expectSame(["config", "x.k"], fixture, environment: ["GIT_CONFIG_GLOBAL": named.path],
                                 sandboxed: sandboxed)
        }
    }

    @Test("a relative GIT_CONFIG_GLOBAL is the working directory's, and --show-origin prints it as typed")
    func relativeGlobalFile() async throws {
        guard Self.hasRealGit else { return }
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try write("[user]\n\tname = Relative\n", to: fixture.work.appendingPathComponent("rel.cfg"))
        try initRepository(fixture.work, home: fixture.home)
        let environment = ["GIT_CONFIG_GLOBAL": "rel.cfg"]
        try await expectSame(["config", "--list", "--show-origin"], fixture, environment: environment)
        try await expectSame(["config", "--show-origin", "user.name"], fixture, environment: environment)
        let shown = try await git(
            ["config", "--list", "--show-origin"], root: fixture.root, home: fixture.home, work: fixture.work,
            environment: environment)
        #expect(shown.stdout.hasPrefix("file:rel.cfg\tuser.name=Relative\n"))
        // Outside a repository too.
        try write("[user]\n\tname = Relative\n", to: fixture.root.appendingPathComponent("rel.cfg"))
        let outside = try await git(
            ["config", "--list", "--show-origin"], root: fixture.root, home: fixture.home, work: fixture.root,
            environment: environment)
        #expect(outside.stdout == "file:rel.cfg\tuser.name=Relative\n")
    }

    @Test("GIT_CONFIG_GLOBAL=/dev/null or empty leaves the home files out of an unscoped read")
    func emptyGlobalFile() async throws {
        guard Self.hasRealGit else { return }
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try write("[user]\n\tname = Home\n", to: fixture.home.appendingPathComponent(".gitconfig"))
        try write("[x]\n\tk = v\n", to: fixture.home.appendingPathComponent(".config/git/config"))
        for inRepository in [false, true] {
            if inRepository { try initRepository(fixture.work, home: fixture.home) }
            for value in ["/dev/null", ""] {
                let environment = ["GIT_CONFIG_GLOBAL": value]
                for sandboxed in [false, true] {
                    try await expectSame(["config", "user.name"], fixture, environment: environment,
                                         sandboxed: sandboxed)
                    try await expectSame(["config", "x.k"], fixture, environment: environment, sandboxed: sandboxed)
                    try await expectSame(["config", "--list"], fixture, environment: environment,
                                         sandboxed: sandboxed)
                }
            }
        }
        // Without the override they are there.
        let plain = try await git(["config", "user.name"], root: fixture.root, home: fixture.home, work: fixture.work)
        #expect(plain.stdout == "Home\n")
    }

    @Test("GIT_CONFIG_NOSYSTEM leaves the system file out of an unscoped read, an explicit --system still reads it")
    func systemFile() async throws {
        guard Self.hasRealGit else { return }
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let system = fixture.root.appendingPathComponent("system.cfg")
        try write("[s]\n\tk = system\n", to: system)
        try initRepository(fixture.work, home: fixture.home)
        let withSystem = ["GIT_CONFIG_SYSTEM": system.path, "GIT_CONFIG_NOSYSTEM": ""]
        let noSystem = ["GIT_CONFIG_SYSTEM": system.path, "GIT_CONFIG_NOSYSTEM": "1"]

        // Unsandboxed, the file is read unless NOSYSTEM says not. (Apple's git
        // reads a system file of Xcode's as well, so what it prints can't be
        // compared here; what git is documented to print is checked.)
        let shown = try await git(["config", "--list", "--show-origin"], root: fixture.root, home: fixture.home,
                                  work: fixture.work, environment: withSystem, sandboxed: false)
        #expect(shown.stdout.hasPrefix("file:\(system.path)\ts.k=system\nfile:.git/config\t"))
        let get = try await git(["config", "s.k"], root: fixture.root, home: fixture.home, work: fixture.work,
                                environment: withSystem, sandboxed: false)
        #expect(get.stdout == "system\n")
        try await expectSame(["config", "--list"], fixture, environment: noSystem)
        try await expectSame(["config", "s.k"], fixture, environment: noSystem)
        try await expectSame(["config", "--system", "s.k"], fixture, environment: noSystem)
        try await expectSame(["config", "--system", "--list"], fixture, environment: noSystem)

        // Also from outside the repository.
        let outside = try await git(["config", "--list"], root: fixture.root, home: fixture.home,
                                    work: fixture.root, environment: withSystem, sandboxed: false)
        #expect(outside.stdout == "s.k=system\n")
        let off = ConfigFixture(root: fixture.root, home: fixture.home, work: fixture.root)
        try await expectSame(["config", "--list"], off, environment: noSystem)
    }

    @Test("a sandbox reads a GIT_CONFIG_SYSTEM file only inside its root, or with the embedder's opt-in")
    func sandboxedSystemFile() async throws {
        let fixture = try makeRoot()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitConfigEnvOutside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: outside)
        }
        let inside = fixture.root.appendingPathComponent("system.cfg")
        try write("[s]\n\tk = inside\n", to: inside)
        let elsewhere = outside.appendingPathComponent("system.cfg")
        try write("[s]\n\tk = outside\n", to: elsewhere)
        func list(_ file: URL) async throws -> String {
            try await git(["config", "--list"], root: fixture.root, home: fixture.home, work: fixture.work,
                          environment: ["GIT_CONFIG_SYSTEM": file.path, "GIT_CONFIG_NOSYSTEM": ""]).stdout
        }

        #expect(try await list(inside) == "s.k=inside\n")
        // The host's file is not read, and not an error either.
        #expect(try await list(elsewhere) == "")
        let allowed = try await GitSandboxPolicy.$allowsHostSystemConfig.withValue(true) {
            try await list(elsewhere)
        }
        #expect(allowed == "s.k=outside\n")
    }

    @Test("a sandbox refuses a GIT_CONFIG_GLOBAL file outside its root, /dev/null excepted")
    func sandboxedGlobalFile() async throws {
        let fixture = try makeRoot()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitConfigEnvOutside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: outside)
        }
        let elsewhere = outside.appendingPathComponent("global.cfg")
        try write("[g]\n\tk = outside\n", to: elsewhere)
        await #expect(throws: Sandbox.Denial.self) {
            try await self.git(["config", "--list"], root: fixture.root, home: fixture.home, work: fixture.work,
                               environment: ["GIT_CONFIG_GLOBAL": elsewhere.path])
        }
        await #expect(throws: Sandbox.Denial.self) {
            try await self.git(["config", "g.k"], root: fixture.root, home: fixture.home, work: fixture.work,
                               environment: ["GIT_CONFIG_GLOBAL": elsewhere.path])
        }
        let none = try await git(["config", "--list"], root: fixture.root, home: fixture.home, work: fixture.work,
                                 environment: ["GIT_CONFIG_GLOBAL": "/dev/null"])
        #expect(none.stdout == "" && none.status == 0)
        // Nor is it refused when it is the file an explicit scope reads.
        let scoped = try await git(["config", "--global", "--list"], root: fixture.root, home: fixture.home,
                                   work: fixture.work, environment: ["GIT_CONFIG_GLOBAL": "/dev/null"])
        #expect(scoped.stdout == "" && scoped.status == 0)
        // An include in a file of the sandbox's own is still refused.
        let included = fixture.root.appendingPathComponent("included.cfg")
        try write("[include]\n\tpath = /etc/gitconfig\n", to: included)
        await #expect(throws: Sandbox.Denial.self) {
            try await self.git(["config", "--list"], root: fixture.root, home: fixture.home, work: fixture.work,
                               environment: ["GIT_CONFIG_GLOBAL": included.path])
        }
    }

    @Test("GIT_CONFIG_COUNT entries are the highest level, shown as `command line:`")
    func commandLineEntries() async throws {
        guard Self.hasRealGit else { return }
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try write("[user]\n\tname = Home\n", to: fixture.home.appendingPathComponent(".gitconfig"))
        let environment = [
            "GIT_CONFIG_COUNT": "3",
            "GIT_CONFIG_KEY_0": "user.name", "GIT_CONFIG_VALUE_0": "Count",
            "GIT_CONFIG_KEY_1": "Core.Whatever", "GIT_CONFIG_VALUE_1": "a=b",
            "GIT_CONFIG_KEY_2": "remote.Origin.url", "GIT_CONFIG_VALUE_2": "",
        ]

        // Outside a repository, then in one (where core.* of its own sits below them).
        for inRepository in [false, true] {
            if inRepository { try initRepository(fixture.work, home: fixture.home) }
            for sandboxed in [false, true] {
                try await expectSame(["config", "--list"], fixture, environment: environment, sandboxed: sandboxed)
                try await expectSame(["config", "--list", "--show-origin"], fixture, environment: environment,
                                     sandboxed: sandboxed)
                try await expectSame(["config", "user.name"], fixture, environment: environment,
                                     sandboxed: sandboxed)
                try await expectSame(["config", "--show-origin", "user.name"], fixture, environment: environment,
                                     sandboxed: sandboxed)
                try await expectSame(["config", "--show-origin", "core.whatever"], fixture,
                                     environment: environment, sandboxed: sandboxed)
                try await expectSame(["config", "--show-origin", "remote.Origin.url"], fixture,
                                     environment: environment, sandboxed: sandboxed)
            }
        }
        let shown = try await git(
            ["config", "--show-origin", "user.name"], root: fixture.root, home: fixture.home,
            work: fixture.work, environment: environment)
        #expect(shown.stdout == "command line:\tCount\n")
        // --local is the repository's file alone.
        let local = try await git(
            ["config", "--local", "user.name"], root: fixture.root, home: fixture.home, work: fixture.work,
            environment: environment)
        #expect(local.status == 1)
    }

    @Test("a GIT_CONFIG_COUNT git can't read stops the command, in git's words")
    func badCommandLineEntries() async throws {
        guard Self.hasRealGit else { return }
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try initRepository(fixture.work, home: fixture.home)
        let cases: [[String: String]] = [
            ["GIT_CONFIG_COUNT": "x"],
            ["GIT_CONFIG_COUNT": "-1"],
            ["GIT_CONFIG_COUNT": "1"],
            ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "a.b"],
            ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "ab", "GIT_CONFIG_VALUE_0": "1"],
            ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "", "GIT_CONFIG_VALUE_0": "1"],
            ["GIT_CONFIG_COUNT": "99999999999999999999"],
            ["GIT_CONFIG_COUNT": "3x"],
            ["GIT_CONFIG_COUNT": " 1"],
            ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": ".b", "GIT_CONFIG_VALUE_0": "1"],
            ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "a b.c", "GIT_CONFIG_VALUE_0": "1"],
            ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "a.1b", "GIT_CONFIG_VALUE_0": "1"],
        ]
        for environment in cases {
            let ours = try await git(
                ["config", "--list"], root: fixture.root, home: fixture.home, work: fixture.work,
                environment: environment, sandboxed: false)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.realGit)
            process.arguments = ["config", "--list"]
            process.currentDirectoryURL = fixture.work
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": fixture.home.path, "GIT_CONFIG_NOSYSTEM": "1"]
                .merging(environment) { $1 }
            let err = Pipe()
            process.standardError = err
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(ours.stderr == message, "\(environment)")
            #expect(ours.status == process.terminationStatus, "\(environment)")
        }
    }

    @Test("without a sandbox the shell's HOME, not the process's, names the home files")
    func shellHomeWithoutSandbox() async throws {
        guard Self.hasRealGit else { return }
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try write("[user]\n\tname = Home\n", to: fixture.home.appendingPathComponent(".gitconfig"))
        try write("[x]\n\tk = v\n", to: fixture.home.appendingPathComponent(".config/git/config"))
        let elsewhere = fixture.root.appendingPathComponent("xdg")
        try write("[y]\n\tk = w\n", to: elsewhere.appendingPathComponent("git/config"))
        try await expectSame(["config", "--list"], fixture)
        try await expectSame(["config", "--list", "--show-origin"], fixture)
        try await expectSame(["config", "--list"], fixture, environment: ["XDG_CONFIG_HOME": elsewhere.path])
        try initRepository(fixture.work, home: fixture.home)
        try await expectSame(["config", "--list", "--show-origin"], fixture)
        try await expectSame(["config", "x.k"], fixture)
        try await expectSame(["config", "y.k"], fixture, environment: ["XDG_CONFIG_HOME": elsewhere.path])
        let plain = try await git(["config", "user.name"], root: fixture.root, home: fixture.home,
                                  work: fixture.work, sandboxed: false)
        #expect(plain.stdout == "Home\n")
    }

    @Test("the identity of a commit comes from the environment's config: GIT_CONFIG_GLOBAL and GIT_CONFIG_COUNT")
    func commitIdentity() async throws {
        guard Self.hasRealGit else { return }
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try write("[user]\n\tname = Home\n\temail = home@example.com\n",
                  to: fixture.home.appendingPathComponent(".gitconfig"))
        let named = fixture.root.appendingPathComponent("named.cfg")
        try write("[user]\n\tname = Named\n\temail = named@example.com\n", to: named)
        try initRepository(fixture.work, home: fixture.home)

        func commit(_ message: String, environment: [String: String], sandboxed: Bool) async throws -> String {
            try write(message, to: fixture.work.appendingPathComponent("file-\(message).txt"))
            _ = try real(["add", "."], home: fixture.home, work: fixture.work)
            let result = try await git(
                ["commit", "-m", message], root: fixture.root, home: fixture.home, work: fixture.work,
                environment: environment, sandboxed: sandboxed)
            #expect(result.status == 0, "\(result.stderr)")
            return try real(["log", "-1", "--format=%an <%ae> / %cn <%ce>"], home: fixture.home, work: fixture.work,
                            environment: ["GIT_CONFIG_GLOBAL": "/dev/null"]).stdout
        }

        for sandboxed in [false, true] {
            let tag = sandboxed ? "sandboxed" : "plain"
            #expect(try await commit("home-\(tag)", environment: [:], sandboxed: sandboxed)
                    == "Home <home@example.com> / Home <home@example.com>\n")
            #expect(try await commit("named-\(tag)", environment: ["GIT_CONFIG_GLOBAL": named.path],
                                     sandboxed: sandboxed)
                    == "Named <named@example.com> / Named <named@example.com>\n")
            let count = [
                "GIT_CONFIG_GLOBAL": named.path, "GIT_CONFIG_COUNT": "2",
                "GIT_CONFIG_KEY_0": "user.name", "GIT_CONFIG_VALUE_0": "Count",
                "GIT_CONFIG_KEY_1": "user.email", "GIT_CONFIG_VALUE_1": "count@example.com",
            ]
            #expect(try await commit("count-\(tag)", environment: count, sandboxed: sandboxed)
                    == "Count <count@example.com> / Count <count@example.com>\n")
        }
    }
}
#endif
