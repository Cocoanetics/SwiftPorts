#if os(macOS) || os(Linux)
import Foundation
import ShellKit
import ShellCommandKit
import Testing
import GitCommand

/// Twin repositories and isolated host config; all subprocesses here are test oracles only.
struct LFSCommandFixture {
    let root: URL
    let ours: URL
    let theirs: URL
    let ourHost = IsolatedGitHost()
    let theirHost = IsolatedGitHost()

    /// `git lfs version` on `PATH`, read once; nil when git-lfs is missing.
    static let installedVersion: String? = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "lfs", "version"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        } catch {
            return nil
        }
    }()

    /// The oracle compares against the pinned git-lfs 3.7.1; other releases word warnings differently.
    static var isAvailable: Bool { isAvailable(installedVersion) }

    static var unavailableReason: Comment { Comment(rawValue: unavailableReason(installedVersion)) }

    static func isAvailable(_ versionOutput: String?) -> Bool {
        versionOutput.map(LFSSamePathOracle.isReferenceRelease) ?? false
    }

    static func unavailableReason(_ versionOutput: String?) -> String {
        guard let versionOutput else { return "git-lfs is not on PATH" }
        let token = versionOutput.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let version = token.hasPrefix("git-lfs/") ? String(token.dropFirst("git-lfs/".count)) : token
        return "oracle needs git-lfs 3.7.1, found \(version)"
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LFSCommand-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        ours = root.appendingPathComponent("ours")
        theirs = root.appendingPathComponent("theirs")
        for repo in [ours, theirs] {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            let result = try system(["init", "-q", "-b", "main"], in: repo)
            #expect(result.status == 0)
        }
    }

    func cleanup() {
        for directory in [root, ourHost.home.deletingLastPathComponent(), theirHost.home.deletingLastPathComponent()] {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func write(_ path: String, _ text: String) throws {
        for repo in [ours, theirs] {
            let url = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: false, encoding: .utf8)
        }
    }

    func system(_ args: [String], in repo: URL, input: Data = Data()) throws -> ConfigOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = repo
        let host = repo.path.hasPrefix(ours.path) ? ourHost : theirHost
        host.isolate(process)
        process.environment?["GIT_CONFIG_SYSTEM"] = host.home.appendingPathComponent("system.gitconfig").path
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ConfigOutput(stdout: String(decoding: stdout, as: UTF8.self),
                            stderr: String(decoding: stderr, as: UTF8.self), status: process.terminationStatus)
    }

    func run(_ args: [String], subdirectory: String = "", input: Data = Data()) async throws -> ConfigOutput {
        let out = OutputSink(), err = OutputSink()
        let shell = Shell(stdin: InputSource.data(input), stdout: out, stderr: err,
                          environment: ourHost.environment(
                            ["GIT_CONFIG_SYSTEM": ourHost.home.appendingPathComponent("system.gitconfig").path],
                            workingDirectory: ours.appendingPathComponent(subdirectory).path))
        shell.sandbox = ourHost.sandbox
        let status = try await shell.withCurrent {
            try await Shell.parsableCommand(GitCommand.self).run(["git", "lfs"] + args)
        }
        out.finish()
        err.finish()
        return ConfigOutput(stdout: await out.readAllString(), stderr: await err.readAllString(), status: status.code)
    }

    @discardableResult
    func compare(_ args: [String], subdirectory: String = "", input: Data = Data()) async throws -> ConfigOutput {
        let expected = try system(["lfs"] + args, in: theirs.appendingPathComponent(subdirectory), input: input)
        let actual = try await run(args, subdirectory: subdirectory, input: input)
        // Twin roots and the installed git executable's absolute path differ by environment.
        func normalize(_ value: String) -> String {
            var value = value
            #if os(macOS)
            // Go's os.Getwd can return /private/var while Foundation spells the same fixture /var.
            if root.path.hasPrefix("/var/") {
                value = value.replacingOccurrences(of: "/private" + root.path, with: root.path)
            }
            #endif
            return value.replacingOccurrences(of: theirs.path, with: ours.path)
                .replacingOccurrences(of: theirHost.home.path, with: ourHost.home.path)
                .replacingOccurrences(of: #"error running [^\n]+? 'config'"#,
                                      with: "error running git 'config'", options: .regularExpression)
        }
        #expect(normalize(actual.stdout) == normalize(expected.stdout), "stdout: \(args)")
        #expect(normalize(actual.stderr) == normalize(expected.stderr), "stderr: \(args)")
        #expect(actual.status == expected.status, "status: \(args)")
        return actual
    }

    func compareFiles(_ paths: [String] = [".gitattributes"]) throws {
        for path in paths + ["pre-push", "post-checkout", "post-commit", "post-merge"].map({ ".git/hooks/" + $0 }) {
            let expected = FileManager.default.contents(atPath: theirs.appendingPathComponent(path).path)
            let actual = FileManager.default.contents(atPath: ours.appendingPathComponent(path).path)
            #expect(actual == expected, "file bytes: \(path)")
        }
        // Upstream iterates Go maps when installing filters, so key order is nondeterministic.
        let expected = try system(["config", "--list", "--local"], in: theirs).stdout.split(separator: "\n").sorted()
        let actual = try system(["config", "--list", "--local"], in: ours).stdout.split(separator: "\n").sorted()
        #expect(actual == expected)
    }
}
#endif
