#if os(macOS) || os(Linux)
import Foundation
import Testing
import ShellKit
import ShellCommandKit
import GitCommand

@Suite("git show blob same-path oracle")
struct GitCommandShowBlobOracleTests {
    @Test func headPath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.compare("HEAD:message.txt", bytes: Data("current\n".utf8))
    }

    @Test func historicalPath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.compare("HEAD~1:message.txt", bytes: Data("original\n".utf8))
    }

    @Test func blobOID() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try fixture.git(["rev-parse", "HEAD:message.txt"])
        let oid = try #require(String(data: result.stdout, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await fixture.compare(oid, bytes: Data("current\n".utf8))
    }

    @Test func binaryBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(String(data: Fixture.binary, encoding: .utf8) == nil)
        try await fixture.compare("HEAD:binary.dat", bytes: Fixture.binary)
    }

    @Test func noTrailingNewline() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.compare("HEAD:no-newline.txt", bytes: Data("no newline".utf8))
    }

    @Test func lfsPointerStaysPointer() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // The worktree and local LFS store contain the payload; show must read the Git blob.
        try await fixture.compare("HEAD:payload.lfs", bytes: Fixture.pointer)
    }

    @Test(arguments: ["binary.dat", "no-newline.txt", "payload.lfs"])
    func annotatedBlobTag(_ path: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = try fixture.git(["rev-parse", "HEAD:\(path)"])
        let oid = try #require(String(data: target.stdout, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A tag without a tagger isolates blob dispatch from the existing tagger-formatting gap.
        let object = "object \(oid)\ntype blob\ntag blob-tag\n\nblob annotation\n"
        let file = fixture.repo.appendingPathComponent(".git/blob-tag")
        try Data(object.utf8).write(to: file)
        let hashed = try fixture.git(["hash-object", "--literally", "-t", "tag", "-w", file.path])
        let tagOID = try #require(String(data: hashed.stdout, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git(["update-ref", "refs/tags/blob-tag", tagOID])
        let payload = try fixture.git(["show", "HEAD:\(path)"]).stdout
        let bytes = Data("tag blob-tag\n\nblob annotation\n".utf8) + payload
        try await fixture.compare("blob-tag", bytes: bytes)
        try await fixture.compare(tagOID, bytes: bytes)
    }

    @Test(arguments: [":message.txt", ":0:message.txt"])
    func indexBlob(_ spec: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.compare(spec, bytes: Data("current\n".utf8))
    }

    @Test(arguments: ["missing-revision", "missing-revision:message.txt",
                      "HEAD:missing-path.txt", "HEAD:untracked.txt",
                      ":missing-path.txt", ":untracked.txt",
                      ":0:missing-path.txt", ":0:untracked.txt", ":1:message.txt"])
    func missingObject(_ spec: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.compare(spec, bytes: Data(), status: 128)
    }

    @Test(arguments: ["HEAD^{/no match: x}", "HEAD^{/no match: x}:missing-path.txt",
                      "missing@{2020-01-01 10:00}", "missing@{2020-01-01 10:00}:message.txt",
                      "no-reflog@{2020-01-01 10:00}", "no-reflog@{2020-01-01 10:00}:message.txt"])
    func bracedRevisionFailure(_ spec: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.git(["-c", "core.logAllRefUpdates=false", "update-ref", "refs/heads/no-reflog", "HEAD"])
        try await fixture.compare(spec, bytes: Data(), status: 128)
    }

    @Test(arguments: ["HEAD:untracked.txt", ":untracked.txt", ":0:untracked.txt",
                      "HEAD:only-in-sub.txt", ":only-in-sub.txt", ":0:only-in-sub.txt"])
    func missingPathFromSubdirectory(_ spec: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let subdirectory = fixture.repo.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try Data("subdirectory only\n".utf8).write(to: subdirectory.appendingPathComponent("only-in-sub.txt"))
        try await fixture.compare(spec, bytes: Data(), status: 128, in: subdirectory)
    }

    private struct Output {
        let stdout: Data
        let stderr: Data
        let status: Int32
    }

    private struct Fixture {
        static let binary = Data([0x00, 0xFF, 0xC3, 0x28, 0x0D, 0x80])
        static let payloadOID = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        static let pointer = Data(("version https://git-lfs.github.com/spec/v1\n"
                                  + "oid sha256:\(payloadOID)\nsize 5\n").utf8)

        let host = IsolatedGitHost(globalConfig: """
        [user]
            name = Show Oracle
            email = show@example.com
        [core]
            autocrlf = false

        """)
        let repo: URL

        init() throws {
            repo = host.home.deletingLastPathComponent().appendingPathComponent("repo")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init", "-q", "-b", "main"])
            try Data("original\n".utf8).write(to: repo.appendingPathComponent("message.txt"))
            try Self.binary.write(to: repo.appendingPathComponent("binary.dat"))
            try Data("no newline".utf8).write(to: repo.appendingPathComponent("no-newline.txt"))
            try Data("*.lfs filter=lfs diff=lfs merge=lfs -text\n".utf8)
                .write(to: repo.appendingPathComponent(".gitattributes"))
            try Self.pointer.write(to: repo.appendingPathComponent("payload.lfs"))
            try git(["add", "."])
            try git(["commit", "-q", "-m", "original"])
            try Data("current\n".utf8).write(to: repo.appendingPathComponent("message.txt"))
            try git(["add", "message.txt"])
            try git(["commit", "-q", "-m", "current"])

            let object = repo.appendingPathComponent(".git/lfs/objects/2c/f2/\(Self.payloadOID)")
            try FileManager.default.createDirectory(
                at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: object)
            try Data("hello".utf8).write(to: repo.appendingPathComponent("payload.lfs"))
            try Data("untracked\n".utf8).write(to: repo.appendingPathComponent("untracked.txt"))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: host.home.deletingLastPathComponent())
        }

        private var variables: [String: String] {
            host.variables.merging([
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"
            ]) { _, new in new }
        }

        private func systemGit(_ args: [String], in directory: URL? = nil) throws -> Output {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + args
            process.currentDirectoryURL = directory ?? repo
            process.environment = variables
            process.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Output(stdout: stdout, stderr: stderr, status: process.terminationStatus)
        }

        @discardableResult
        func git(_ args: [String]) throws -> Output {
            let result = try systemGit(args)
            let message = String(data: result.stderr, encoding: .utf8) ?? ""
            try #require(result.status == 0, "fixture git \(args): \(message)")
            return result
        }

        func compare(_ spec: String, bytes: Data, status: Int32 = 0, in directory: URL? = nil) async throws {
            let expected = try systemGit(["show", spec], in: directory)
            #expect(expected.stdout == bytes)
            #expect(expected.status == status)
            let out = OutputSink(), err = OutputSink()
            let shell = Shell(
                stdin: .data(Data()), stdout: out, stderr: err,
                environment: Environment(variables: variables, workingDirectory: (directory ?? repo).path))
            shell.sandbox = host.sandbox
            let actualStatus = try await shell.withCurrent {
                try await Shell.parsableCommand(GitCommand.self).run(["git", "show", spec])
            }
            out.finish()
            err.finish()
            let stdout = await out.readAllData()
            let stderr = await err.readAllData()
            #expect(stdout == expected.stdout, "stdout bytes for \(spec) differ from system git")
            #expect(stderr == expected.stderr,
                    "stderr for \(spec): \(String(data: stderr, encoding: .utf8) ?? "")")
            #expect(actualStatus.code == expected.status, "status for \(spec)")
        }
    }
}
#endif
