// Review regressions for GIT_CONFIG_* handling, each checked against /usr/bin/git.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ShellKit
import SwiftGit
@testable import GitCommand

@Suite("git config environment: review regressions")
struct GitCommandConfigReviewTests: ConfigTestHelpers {

    private static let realGit = "/usr/bin/git"
    private static var hasRealGit: Bool { FileManager.default.isExecutableFile(atPath: realGit) }

    private func real(_ args: [String], work: URL, environment: [String: String]) throws -> (out: String, err: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.realGit)
        process.arguments = args
        process.currentDirectoryURL = work
        process.environment = ["PATH": "/usr/bin:/bin"].merging(environment) { $1 }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), String(decoding: errData, as: UTF8.self),
                process.terminationStatus)
    }

    @Test("git init takes init.defaultBranch from GIT_CONFIG_COUNT and GIT_CONFIG_GLOBAL")
    func initDefaultBranch() async throws {
        guard Self.hasRealGit else { return }
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let named = fixture.root.appendingPathComponent("named.cfg")
        try "[init]\n\tdefaultBranch = fromfile\n".write(to: named, atomically: true, encoding: .utf8)
        let cases: [[String: String]] = [
            ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "init.defaultBranch", "GIT_CONFIG_VALUE_0": "counted"],
            ["GIT_CONFIG_GLOBAL": named.path],
        ]
        for environment in cases {
            let work = fixture.root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let ours = try await git(["init"], root: fixture.root, home: fixture.home, work: work,
                                     environment: environment, sandboxed: false)
            #expect(ours.status == 0, "\(ours.stderr)")
            let head = try String(contentsOf: work.appendingPathComponent(".git/HEAD"), encoding: .utf8)
            let expected = environment["GIT_CONFIG_GLOBAL"] == nil ? "counted" : "fromfile"
            #expect(head == "ref: refs/heads/\(expected)\n")
        }
    }

    @Test("an invalid GIT_CONFIG_NOSYSTEM is fatal, as in git")
    func badNoSystem() async throws {
        guard Self.hasRealGit else { return }
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let environment = ["GIT_CONFIG_NOSYSTEM": "garbage"]
        let ours = try await git(["config", "--list"], root: fixture.root, home: fixture.home, work: fixture.work,
                                 environment: environment, sandboxed: false)
        let theirs = try real(["config", "--list"], work: fixture.work,
                              environment: ["HOME": fixture.home.path].merging(environment) { $1 })
        #expect(theirs.status == 128)
        #expect(ours.status == 128)
        // git 2.54 (and this port) say "environment value"; older /usr/bin/git
        // on Linux still says "config value". Both exit 128 naming the variable.
        #expect(ours.stderr.contains("fatal: bad boolean environment value 'garbage' for 'GIT_CONFIG_NOSYSTEM'"))
        #expect(theirs.err.contains("'garbage'"), "\(theirs.err)")
        #expect(theirs.err.contains("GIT_CONFIG_NOSYSTEM"), "\(theirs.err)")
    }

    @Test("--show-origin keeps the key diagnostic and exit 1")
    func showOriginInvalidKey() async throws {
        guard Self.hasRealGit else { return }
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ours = try await git(["config", "--show-origin", "invalid"], root: fixture.root, home: fixture.home,
                                 work: fixture.work, sandboxed: false)
        let theirs = try real(["config", "--show-origin", "invalid"], work: fixture.work,
                              environment: ["HOME": fixture.home.path, "GIT_CONFIG_NOSYSTEM": "1"])
        #expect(theirs.status == 1)
        #expect(ours.status == theirs.status)
        #expect(ours.stderr == theirs.err, "\(ours.stderr)")
    }

    @Test("an empty HOME makes --global read /.gitconfig, never the host's HOME")
    func homeEmptyOrMissing() async throws {
        guard Self.hasRealGit else { return }
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "[user]\n\tname = Host\n".write(
            to: fixture.home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        // Poison the process HOME so a regression that falls back to
        // ProcessInfo would return "Host". Restore it: other suites (e.g.
        // GitHub's ConfigFileStore path test) read the process HOME.
        let savedHome = getenv("HOME").map { String(cString: $0) }
        setenv("HOME", fixture.home.path, 1)
        defer {
            if let savedHome { setenv("HOME", savedHome, 1) } else { unsetenv("HOME") }
        }
        let empty = try await git(["config", "user.name"], root: fixture.root, home: fixture.home,
                                  work: fixture.work, environment: ["HOME": ""], sandboxed: false)
        #expect(empty.status == 1)
        #expect(empty.stdout == "")
    }
}
#endif
