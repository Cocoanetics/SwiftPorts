// `git lfs checkout` / `pull` progress against git-lfs 3.7.1 (issue #274),
// in a repository whose LFS objects are all present. The meter writes to
// stdout. Off a terminal git-lfs 3.7.1 still prints the final `, done.` line
// (`tasklog.Logger.logTask` skips only the `\r` updates), and a local
// checkout's rate is `0 B/s`: the first `TransferBytes` sample is measured
// from Go's zero time. On a terminal lines are padded to its width. A busy
// git-lfs sometimes exits before its logger goroutine writes the done line;
// that drop is a race, not a rule, so the oracle is asked again.
#if os(macOS) || os(Linux)
import Foundation
import ShellKit
import SwiftGit
import Testing
@testable import GitLFSKit

extension LFSFilterTests {
    @Suite("LFS checkout / pull progress oracle (git-lfs 3.7.1)",
           .enabled(if: LFSOracle.isVersion371Available, "git-lfs 3.7.1 is not on PATH"))
    struct LFSCheckoutProgressOracleTests {
        private static let files: [(path: String, data: Data)] = [
            ("a.dat", Data("alpha progress\n".utf8)),
            ("sub/b.dat", Data(repeating: 0x42, count: 4096)),
            ("c.dat", Data("gamma progress\n".utf8))
        ]
        private static let done = "Checking out LFS objects: 100% (3/3), 4.1 KB | 0 B/s, done.\n"

        /// A repository committed by system git with git-lfs 3.7.1's filter,
        /// so every object is in the local store and every file is smudged.
        private func fixture(_ oracle: LFSOracle) throws -> URL {
            let repo = try oracle.makeDirectory("repo")
            try oracle.git(["init", "-q", "-b", "main"], in: repo)
            try oracle.git(["lfs", "install", "--local"], in: repo)
            // Nothing is downloaded; a request here would fail.
            try oracle.git(["config", "lfs.url", "http://127.0.0.1:9/info/lfs"], in: repo)
            try Data("*.dat filter=lfs diff=lfs merge=lfs -text\n".utf8)
                .write(to: repo.appendingPathComponent(".gitattributes"))
            for file in Self.files {
                let url = repo.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: url)
            }
            try oracle.git(["add", "."], in: repo)
            try oracle.git(["-c", "user.name=LFS", "-c", "user.email=lfs@example.com",
                            "commit", "-q", "-m", "fixture"], in: repo)
            return repo
        }

        /// git-lfs 3.7.1 off a terminal, asked again while the done line raced exit.
        private func reference(
            _ args: [String], oracle: LFSOracle, in repo: URL, environment: [String: String] = [:]
        ) throws -> (out: String, err: String, status: Int32) {
            var result = (out: "", err: "", status: Int32(0))
            for _ in 0..<8 {
                let run = try oracle.run(args, in: repo, environment: environment)
                result = (String(decoding: run.out, as: UTF8.self), run.err, run.status)
                if !result.out.isEmpty { break }
            }
            return result
        }

        /// Our checkout, or pull, with what the meter streams placed before the result's stdout.
        private func port(
            pull: Bool = false, oracle: LFSOracle, in repo: URL, terminal: Bool = false,
            columns: Int = 80, variables: [String: String] = [:]
        ) async throws -> LFSCommandResult {
            let shell = Shell(environment: Environment(
                variables: oracle.variables.merging(variables) { $1 }, workingDirectory: repo.path))
            shell.sandbox = oracle.host.sandbox
            return try await shell.withCurrent {
                let git = GitClient(workingDirectory: repo)
                let client = await LFSClient(git: git)
                let streamed = TransferTestLock("")
                var environment = LFSTransferEnvironment()
                environment.stdout = { text in streamed.withLock { $0 += text } }
                environment.terminalWidth = { columns }
                var result = pull
                    ? try await PullOptions().run(
                        [], client: client, git: git, terminal: terminal, environment: environment)
                    : try await CheckoutOptions().run(
                        [], client: client, git: git, terminal: terminal, environment: environment)
                result.stdout = streamed.withLock { $0 } + result.stdout
                return result
            }
        }

        @Test("off a terminal checkout prints git-lfs's done line, at 0 B/s")
        func checkoutOffTerminal() async throws {
            let oracle = LFSOracle()
            defer { try? FileManager.default.removeItem(at: oracle.root) }
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            let repo = try fixture(oracle)

            let theirs = try reference(["lfs", "checkout"], oracle: oracle, in: repo)
            let ours = try await port(oracle: oracle, in: repo)
            #expect(theirs.status == 0 && ours.status == 0)
            #expect(theirs.out == Self.done)
            #expect(ours.stdout == theirs.out)
            #expect(ours.stderr == theirs.err && ours.stderr.isEmpty)
        }

        @Test("on a terminal checkout pads to its width like git-lfs", arguments: [80, 100])
        func checkoutOnTerminal(columns: Int) async throws {
            let oracle = LFSOracle()
            defer { try? FileManager.default.removeItem(at: oracle.root) }
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            let repo = try fixture(oracle)

            // The done line can race git-lfs's exit here too; ask again until it arrives.
            var status: Int32 = 0
            var theirs = ""
            for _ in 0..<8 {
                let run = try oracle.runInTerminal(["lfs", "checkout"], in: repo, columns: columns)
                status = run.status
                theirs = String(decoding: run.out, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
                if theirs.hasSuffix(", done.\n") { break }
            }
            let ours = try await port(oracle: oracle, in: repo, terminal: true, columns: columns)
            #expect(status == 0 && ours.status == 0)
            #expect(ours.stderr.isEmpty)

            // Updates after the first fall inside the 200 ms throttle unless the run is slow.
            let first = "Checking out LFS objects:   0% (0/1), 0 B | 0 B/s"
            let update = first + String(repeating: " ", count: columns - first.count) + "\r"
            for output in [theirs, ours.stdout] {
                #expect(output.hasPrefix(update), "\(output.debugDescription)")
                #expect(output.hasSuffix("\r" + Self.done), "\(output.debugDescription)")
                let updates = output.split(separator: "\r", omittingEmptySubsequences: false).dropLast()
                #expect(updates.allSatisfy { $0.utf8.count == columns }, "\(output.debugDescription)")
            }
        }

        @Test("GIT_LFS_PROGRESS logs the same checkout lines")
        func checkoutProgressLog() async throws {
            let oracle = LFSOracle()
            defer { try? FileManager.default.removeItem(at: oracle.root) }
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            let repo = try fixture(oracle)
            let theirLog = oracle.root.appendingPathComponent("logs/theirs.log")
            let ourLog = oracle.root.appendingPathComponent("logs/ours.log")

            let theirs = try oracle.run(
                ["lfs", "checkout"], in: repo, environment: ["GIT_LFS_PROGRESS": theirLog.path])
            let ours = try await port(
                oracle: oracle, in: repo, variables: ["GIT_LFS_PROGRESS": ourLog.path])
            #expect(theirs.status == 0 && ours.status == 0)
            let expected = "checkout 1/3 15/4126 a.dat\ncheckout 2/3 15/4126 c.dat\n"
                + "checkout 3/3 4096/4126 sub/b.dat\n"
            #expect(try String(contentsOf: theirLog, encoding: .utf8) == expected)
            #expect(try String(contentsOf: ourLog, encoding: .utf8) == expected)
        }

        @Test("pull with every object present prints nothing, on a terminal or off one")
        func pullAllPresent() async throws {
            let oracle = LFSOracle()
            defer { try? FileManager.default.removeItem(at: oracle.root) }
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            let repo = try fixture(oracle)

            let piped = try oracle.run(["lfs", "pull"], in: repo)
            let terminal = try oracle.runInTerminal(["lfs", "pull"], in: repo, columns: 100)
            #expect(piped.status == 0 && terminal.status == 0)
            #expect(piped.out.isEmpty && piped.err.isEmpty && terminal.out.isEmpty)
            for onTerminal in [false, true] {
                let ours = try await port(pull: true, oracle: oracle, in: repo, terminal: onTerminal, columns: 100)
                #expect(ours.status == 0)
                #expect(ours.stdout.isEmpty && ours.stderr.isEmpty)
            }
        }
    }
}
#endif
