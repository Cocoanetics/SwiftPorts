#if os(macOS) || os(Linux)
import Foundation
import Testing
import SwiftGit
import GitLFSKit

/// Same-path contract: one cwd and isolated HOME/XDG/config for both binaries.
/// Kept separate from the twin-repository command fixture used by other LFS commands.
struct LFSEnvOracleFixture {
    private final class BundleMarker: NSObject {}
    let host = IsolatedLFSHost()
    let git: String
    let lfs: String
    let executable: String
    let execPath: String

    init() throws {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        git = try #require(path.components(separatedBy: ":").map {
            URL(fileURLWithPath: $0).appendingPathComponent("git").path
        }.first { FileManager.default.isExecutableFile(atPath: $0) })
        #if os(macOS)
        var directory = Bundle(for: BundleMarker.self).bundleURL
        #else
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        #endif
        var built: String?
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("git").path
            if FileManager.default.isExecutableFile(atPath: candidate) { built = candidate; break }
            directory.deleteLastPathComponent()
        }
        executable = try #require(built, "Build the git executable with the tests")
        let result = try LFSEnvProcess.run(
            git, ["--exec-path"], cwd: host.root,
            environment: ["PATH=" + path, "GIT_CONFIG_NOSYSTEM=1"], output: host.root)
        execPath = result.stdout.trimmingCharacters(in: .newlines)
        lfs = try #require(([execPath] + path.components(separatedBy: ":")).map {
            URL(fileURLWithPath: $0).appendingPathComponent("git-lfs").path
        }.first { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// Deliberately non-alphabetical GIT_* entries, with GIT_EXEC_PATH already
    /// present so system git doesn't append a variable only to its own child.
    func environment(_ extra: [String] = []) -> [String] {
        ["PATH=" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
         "HOME=" + host.home.path, "XDG_CONFIG_HOME=" + host.xdgConfigHome.path,
         "LC_ALL=C", "GIT_Z_ENV_TEST=last-in-alphabet", "GIT_CONFIG_NOSYSTEM=1",
         "GIT_EXEC_PATH=" + execPath, "GIT_CONFIG_GLOBAL=" + host.globalConfig.path,
         "GIT_A_ENV_TEST=first-in-alphabet", "TEST_GIT_IGNORED=GIT_NOT_AN_ENTRY"] + extra
    }

    @discardableResult
    func system(_ args: [String], cwd: URL, extra: [String] = []) throws -> String {
        let result = try LFSEnvProcess.run(git, args, cwd: cwd, environment: environment(extra), output: host.root)
        #expect(result.status == 0, "\(args): \(result.stderr)")
        return result.stdout
    }

    func compare(_ cwd: URL, extra: [String] = []) throws {
        let environment = environment(extra)
        let reference = try LFSEnvProcess.run(
            lfs, ["env"], cwd: cwd, environment: environment, output: host.root)
        let actual = try LFSEnvProcess.run(
            executable, ["lfs", "env"], cwd: cwd, environment: environment, output: host.root)
        var expected = reference.stdout.components(separatedBy: "\n")
        #expect(expected.count > 3)
        expected[0] = LFSVersion.string
        expected[1] = PortVersion.gitLine
        #expect(actual.stdout == expected.joined(separator: "\n"))
        #expect(actual.stderr == reference.stderr)
        #expect(actual.status == reference.status)
        #expect(actual.status == 0)
        let inputEntries = environment.filter { $0.hasPrefix("GIT_") }
        let outputEntries = actual.stdout.components(separatedBy: "\n").filter { $0.hasPrefix("GIT_") }
        #expect(outputEntries == inputEntries)
        let referenceEntries = reference.stdout.components(separatedBy: "\n").filter { $0.hasPrefix("GIT_") }
        #expect(referenceEntries == inputEntries)
    }

    func repository(_ name: String, bare: Bool = false) throws -> URL {
        let directory = host.root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try system(["init", "-q", "-b", "main"] + (bare ? ["--bare"] : []), cwd: directory)
        return directory
    }

    func config(_ key: String, _ value: String, cwd: URL) throws {
        try system(["config", key, value], cwd: cwd)
    }

    func cleanup() { try? FileManager.default.removeItem(at: host.root) }
}
#endif
