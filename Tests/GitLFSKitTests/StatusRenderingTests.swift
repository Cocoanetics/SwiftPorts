import Foundation
import Testing
import Crypto
import ShellKit
import SwiftGit
@testable import GitLFSKit

@Suite("LFS status rendering")
struct StatusRenderingTests {
    private static let zero = String(repeating: "0", count: 40)
    private static let pointer = Pointer(oid: String(repeating: "a", count: 64), size: 123)

    private func withRepo(_ body: (IsolatedLFSHost, URL, GitClient) async throws -> Void) async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let (dir, client) = try await LFSFixture.make(host, "status-render")
            let shell = Shell(environment: Environment(variables: host.variables, workingDirectory: dir.path))
            shell.sandbox = host.sandbox
            try await shell.withCurrent { try await body(host, dir, client) }
        }
    }

    private func stage(_ text: String, _ name: String, in dir: URL, client: GitClient) async throws -> String {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
        try await client.add(paths: [name])
        return try #require(try await client.indexedEntries().first { $0.path == name }).oid
    }

    private func entry(_ status: Character, _ old: String, _ new: String,
                       _ source: String, to destination: String = "") -> DiffIndexEntry {
        DiffIndexEntry(oldMode: 0o100644, newMode: 0o100644, oldOID: old, newOID: new,
                       status: status, sourcePath: source, destinationPath: destination)
    }

    @Test func unbornAndEmptyFormats() async throws {
        try await withRepo { _, _, client in
            var options = StatusOptions()
            let human = try await options.status(client: client)
            #expect(human.stdout == "\nObjects to be committed:\n\n\nObjects not staged for commit:\n\n\n")
            #expect(human.stderr.isEmpty && human.status == 0)
            options.json = true
            #expect(try await options.status(client: client).stdout == "{\"files\":{}}\n")
            options.porcelain = true
            #expect(try await options.status(client: client).stdout == "")
        }
    }

    #if os(macOS) || os(Linux)
    @Test("filesystem-root paths retain git-lfs 3.7.1's relativize behavior")
    func filesystemRootPathsMatchUpstream() async throws {
        try await withRepo { host, dir, client in
            let oid = try await stage(Self.pointer.encoded, "file.bin", in: dir, client: client)
            let index = StatusIndex(staged: [entry("A", Self.zero, oid, "file.bin")], unstaged: [])
            let shell = Shell(environment: Environment(variables: host.variables, workingDirectory: "/"))
            shell.sandbox = host.sandbox
            try await shell.withCurrent {
                var output = ""
                // The pinned source splits "/" into ["", ""], retaining one extra
                // component relative to "/file.bin". Preserve its observable output.
                try await StatusOptions().renderHuman(index, client: client, root: URL(fileURLWithPath: "/"),
                                                      output: &output)
                #expect(output == "\nObjects to be committed:\n\n\t../file.bin (LFS: aaaaaaa)\n"
                        + "\nObjects not staged for commit:\n\n\n")
            }
        }
    }
    #endif

    @Test func additionsAndBothSidesOfModification() async throws {
        try await withRepo { _, dir, client in
            _ = try await stage(Self.pointer.encoded, "a.bin", in: dir, client: client)
            _ = try await client.commit(message: "base", author: nil, allowEmpty: false)
            let second = Pointer(oid: String(repeating: "b", count: 64), size: 124)
            _ = try await stage(second.encoded, "a.bin", in: dir, client: client)
            _ = try await stage(Self.pointer.encoded, "added.bin", in: dir, client: client)
            _ = try await stage("ordinary", "plain.txt", in: dir, client: client)
            try Data("worktree".utf8).write(to: dir.appendingPathComponent("a.bin"))
            let hash = SHA256.hash(data: Data("worktree".utf8)).map { String(format: "%02x", $0) }.joined()
            var options = StatusOptions()
            let human = try await options.status(client: client)
            #expect(human.stdout == "On branch main\n\nObjects to be committed:\n\n"
                    + "\ta.bin (LFS: aaaaaaa -> LFS: bbbbbbb)\n\tadded.bin (LFS: aaaaaaa)\n"
                    + "\tplain.txt (Git: 0382237)\n\nObjects not staged for commit:\n\n"
                    + "\ta.bin (LFS: aaaaaaa -> File: \(hash.prefix(7)))\n\n")
            #expect(human.status == 0 && human.stderr.isEmpty)
            options.json = true
            #expect(try await options.status(client: client).stdout
                    == "{\"files\":{\"a.bin\":{\"status\":\"M\"},\"added.bin\":{\"status\":\"A\"}}}\n")
            options.porcelain = true
            #expect(try await options.status(client: client).stdout == " M a.bin\nA  added.bin\nA  plain.txt\n")
        }
    }

    @Test func sourceAndDestinationAnnotationsAndPaths() async throws {
        try await withRepo { host, dir, client in
            let oid = try await stage(Self.pointer.encoded, "old.bin", in: dir, client: client)
            let second = Pointer(oid: String(repeating: "b", count: 64), size: 124)
            let new = try await stage(second.encoded, "new.bin", in: dir, client: client)
            let subdir = dir.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            let shell = Shell(environment: Environment(variables: host.variables, workingDirectory: subdir.path))
            shell.sandbox = host.sandbox
            try await shell.withCurrent {
                let rename = entry("R", oid, new, "old.bin", to: "new.bin")
                let index = StatusIndex(staged: [rename], unstaged: [rename])
                var human = ""
                let options = StatusOptions()
                try await options.renderHuman(index, client: client, root: dir, output: &human)
                #expect(human == "\nObjects to be committed:\n\n"
                        + "\t../old.bin -> ../new.bin (LFS: aaaaaaa -> LFS: bbbbbbb)\n"
                        + "\nObjects not staged for commit:\n\n"
                        + "\t../old.bin (LFS: aaaaaaa -> LFS: bbbbbbb)\n\n")
                #expect(StatusOptions.renderPorcelain(index) == "R  old.bin -> new.bin\n")
                #expect(try await options.renderJSON(index, client: client, root: dir)
                        == "{\"files\":{\"new.bin\":{\"status\":\"R\",\"from\":\"old.bin\"}}}\n")
                let addition = entry("A", Self.zero, new, "absent.bin", to: "new.bin")
                #expect(try await options.formatBlobInfo(addition, scanner: PointerScanner(client: client), root: dir)
                        == "LFS: bbbbbbb")
            }
        }
    }

    @Test func machineOrderFilteringAndOverwrite() async throws {
        try await withRepo { _, dir, client in
            let lfs = try await stage(Self.pointer.encoded, "lfs", in: dir, client: client)
            let git = try await stage("ordinary", "plain", in: dir, client: client)
            let index = StatusIndex(staged: [
                entry("D", lfs, Self.zero, "same"),
                entry("C", lfs, lfs, "lfs", to: "copy"),
                entry("A", Self.zero, lfs, "added"),
                entry("T", git, lfs, "plain")
            ], unstaged: [entry("M", lfs, Self.zero, "same"), entry("U", git, Self.zero, "conflict")])
            #expect(StatusOptions.renderPorcelain(index)
                    == " M same\nU  conflict\nC  lfs -> copy\nA  added\nT  plain\n")
            #expect(try await StatusOptions().renderJSON(index, client: client, root: dir)
                    == "{\"files\":{\"added\":{\"status\":\"A\"},"
                    + "\"copy\":{\"status\":\"C\",\"from\":\"lfs\"},\"same\":{\"status\":\"D\"}}}\n")
        }
    }

    @Test func jsonByteOrderingEscapingAndCodable() throws {
        var status = JSONStatus()
        for name in ["é", "e\u{301}", "a/<>&\u{2028}\u{2029}\n\t\"\\", "Z"] {
            status.files[Data(name.utf8)] = JSONStatusEntry(status: "R", from: "a/b")
        }
        let expected = "{\"files\":{\"Z\":{\"status\":\"R\",\"from\":\"a/b\"},"
            + "\"a/\\u003c\\u003e\\u0026\\u2028\\u2029\\n\\t\\\"\\\\\":{\"status\":\"R\",\"from\":\"a/b\"},"
            + "\"e\u{301}\":{\"status\":\"R\",\"from\":\"a/b\"},\"é\":{\"status\":\"R\",\"from\":\"a/b\"}}}"
        #expect(try status.json() == expected)
        // A single path also round trips through the standard Codable interface.
        let data = Data("{\"files\":{\"a\":{\"status\":\"A\"}}}".utf8)
        let decoded = try JSONDecoder().decode(JSONStatus.self, from: data)
        #expect(try decoded.json() == "{\"files\":{\"a\":{\"status\":\"A\"}}}")
        #expect(try JSONDecoder().decode(JSONStatus.self, from: JSONEncoder().encode(decoded)).json()
                == decoded.json())
    }

    @Test func trackingFetchConfigAndDetachedHEAD() async throws {
        try await withRepo { _, dir, client in
            _ = try await stage("base", "plain", in: dir, client: client)
            _ = try await client.commit(message: "base", author: nil, allowEmpty: false)
            let base = try await client.resolveOID("HEAD")
            let refs = dir.appendingPathComponent(".git/refs/remotes/upstream")
            try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
            for name in ["topic", "main"] {
                try (base + "\n").write(to: refs.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            _ = try await stage(Self.pointer.encoded, "a.bin", in: dir, client: client)
            _ = try await client.commit(message: "lfs", author: nil, allowEmpty: false)
            try await client.configSet("branch.main.remote", "upstream")
            try await client.configSet("branch.main.merge", "refs/heads/topic")
            try await client.configSet("branch.main.pushRemote", "push")
            try await client.configSet("remote.pushDefault", "push")
            var output = try await StatusOptions().status(client: client)
            #expect(output.stdout.hasPrefix("On branch main\nObjects to be pushed to upstream/topic:\n\n"
                                           + "\ta.bin (\(Self.pointer.oid))\n"))
            #expect(output.status == 0 && output.stderr.isEmpty)
            for merge in ["refs/tags/topic", "topic", ""] {
                try await client.configSet("branch.main.merge", merge)
                output = try await StatusOptions().status(client: client)
                #expect(output.stdout.contains("Objects to be pushed to upstream/main:\n"))
            }
            try await client.configSet("branch.main.merge", "refs/heads/missing")
            #expect(try await StatusOptions().status(client: client).stdout
                    == "On branch main\n\nObjects to be committed:\n\n\nObjects not staged for commit:\n\n\n")
            try await client.checkout(ref: base)
            #expect(try await StatusOptions().status(client: client).stdout.hasPrefix("On branch HEAD\n\n"))
        }
    }

    @Test func repositoryFailuresAndPartialOutput() async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let outside = try await StatusOptions().status(client: GitClient(workingDirectory: host.root))
            #expect(outside.stdout == "Not in a Git repository.\n" && outside.stderr.isEmpty && outside.status == 128)
            let bareDir = host.root.appendingPathComponent("bare")
            let bare = GitClient(workingDirectory: bareDir)
            try await bare.initRepository(bare: true)
            let result = try await StatusOptions().status(client: bare)
            #expect(result.stdout == "This operation must be run in a work tree.\n")
            #expect(result.status == 128 && result.stderr.isEmpty)
        }
        try await withRepo { host, dir, client in
            _ = try await stage("ordinary", "a.bin", in: dir, client: client)
            _ = try await client.commit(message: "base", author: nil, allowEmpty: false)
            _ = try await stage(Self.pointer.encoded, "added.bin", in: dir, client: client)
            try Data("changed".utf8).write(to: dir.appendingPathComponent("a.bin"))
            let shell = Shell(environment: Environment(variables: host.variables, workingDirectory: dir.path))
            shell.sandbox = host.sandbox(refusing: { $0.lastPathComponent == "a.bin" })
            let failure = try await shell.withCurrent { try await StatusOptions().status(client: client) }
            #expect(failure.stdout == "On branch main\n")
            #expect(failure.status == 2 && !failure.stderr.isEmpty)

            // Refresh authorizes all indexed files first; render the already-scanned
            // records separately to exercise a later annotation failure as well.
            let options = StatusOptions()
            let index = try await options.scanIndex(client: client, repositoryRoot: dir)
            var output = ""
            await #expect(throws: Sandbox.Denial.self) {
                try await shell.withCurrent {
                    try await options.renderHuman(index, client: client, root: dir, output: &output)
                }
            }
            #expect(output == "\nObjects to be committed:\n\n"
                    + "\tadded.bin (LFS: aaaaaaa)\n\nObjects not staged for commit:\n\n")
        }
    }
}
