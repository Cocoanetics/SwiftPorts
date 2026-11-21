#if os(macOS) || os(Linux)
import Foundation
import Testing
import ShellKit
import CGitKit
@testable import SwiftGit

@Suite("GitClient.refreshIndex")
struct GitClientRefreshIndexTests {
    private let support = GitClientDiffIndexRefreshTests()
    private let past = Date(timeIntervalSince1970: 1_577_833_200)

    @Test("refresh hashes smudged content through the clean filter")
    func refreshIndexHashesThroughCleanFilter() async throws {
        let dir = try filteredRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let driver = try driverName(in: dir)
        let client = GitClient(workingDirectory: dir)
        let index = dir.appendingPathComponent(".git/index")
        let before = try Data(contentsOf: index)
        let staged = try support.runGit(["ls-files", "-s"], in: dir)
        let objects = try support.runGit(["count-objects", "-v"], in: dir)

        // With no registered clean filter, raw X cannot match pointer(X).
        try await client.refreshIndex(paths: ["f"])
        #expect(try Data(contentsOf: index) == before)
        #expect(try await client.diffIndex(cached: false).map(\.destinationPath) == ["f"])
        #expect(try gitExit(["diff-index", "--quiet", "HEAD", "--"], in: dir) == 1)

        try GitFilters.register(name: driver, .buffered(clean: { source, data in
            #expect(source.direction == .clean)
            #expect(source.path == "f")
            return Data("pointer(\(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)))\n".utf8)
        }))
        defer { try? GitFilters.unregister(name: driver) }
        // The old raw-byte refresh still leaves this path stale.
        #expect(try await client.diffIndex(cached: false, refresh: true).map(\.destinationPath) == ["f"])
        try await client.refreshIndex(paths: ["f", "f"])
        #expect(try gitExit(["diff-index", "--quiet", "HEAD", "--"], in: dir) == 0)
        #expect(try await client.diffIndex(cached: false).isEmpty)
        #expect(try support.runGit(["ls-files", "-s"], in: dir) == staged)
        #expect(try support.runGit(["count-objects", "-v"], in: dir) == objects)

        // A matching stat must neither invoke the filter nor rewrite the index.
        try GitFilters.unregister(name: driver)
        try GitFilters.register(name: driver, GitFilter(clean: { _, _ in
            Issue.record("a matching stat must not hash through the filter")
            return nil
        }))
        let refreshed = try snapshot(in: dir)
        try await client.refreshIndex(paths: ["f"])
        try expectUnchanged(refreshed, in: dir)
    }

    @Test("a matching 5 GiB stat neither runs the clean filter nor rewrites the index")
    func largeFileStat() async throws {
        let dir = try filteredRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = GitClient(workingDirectory: dir)
        let file = dir.appendingPathComponent("f")
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 5 * 1_024 * 1_024 * 1_024)
        try handle.close()
        // Keep the work-tree mtime older than snapshot's index mtime, so
        // neither Git nor libgit2 treats the manually seeded stat as racy.
        try FileManager.default.setAttributes(
            [.modificationDate: past.addingTimeInterval(-60)], ofItemAtPath: file.path)
        let stat = try #require(DiffIndexWorktree.fileStat(file.path))
        #expect(stat.size == 5 * 1_024 * 1_024 * 1_024)
        var index: OpaquePointer?
        try GitClient.check(git_index_open(&index, dir.appendingPathComponent(".git/index").path))
        defer { git_index_free(index) }
        // Model the stat saved by an earlier successful refresh, without
        // reading or storing 5 GiB just to arrange the matching-stat case.
        try DiffIndexStat.rewriteStat(index, path: "f", file: stat)
        try GitClient.check(git_index_write(index))
        let cachedSize = try #require(git_index_get_bypath(index, "f", 0)?.pointee.file_size)
        #expect(cachedSize == UInt32(1_073_741_824))
        let driver = try driverName(in: dir)
        // An attempted hash must fail while loading filters, before libgit2
        // buffers 5 GiB. Matching stat must not need this required driver.
        try support.runGit(["config", "filter.\(driver).required", "true"], in: dir)
        try GitFilters.enforceRequiredDrivers()
        let before = try snapshot(in: dir)
        try await client.refreshIndex(paths: ["f"])
        try expectUnchanged(before, in: dir)
        try support.runGit(["update-index", "-q", "--refresh"], in: dir)
        #expect(try Data(contentsOf: dir.appendingPathComponent(".git/index")) == before.0)
    }

    @Test("content mismatch does not rewrite or stage the index", arguments: ["x\n", "longer change\n"])
    func contentMismatch(content: String) async throws {
        let dir = try support.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(content.utf8).write(to: dir.appendingPathComponent("a.txt"))
        try touch("a.txt", in: dir)
        let before = try snapshot(in: dir)
        try await GitClient(workingDirectory: dir).refreshIndex(paths: ["a.txt"])
        try expectUnchanged(before, in: dir)
        #expect(try gitExit(["diff-index", "--quiet", "HEAD", "--", "a.txt"], in: dir) == 1)
    }

    @Test("a clean-filter content mismatch leaves the index and object database unchanged")
    func filteredContentMismatch() async throws {
        let dir = try filteredRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let driver = try driverName(in: dir)
        try GitFilters.register(name: driver, .buffered(clean: { _, data in
            #expect(data == Data("Y\n".utf8))
            return Data("pointer(Y)\n".utf8)
        }))
        defer { try? GitFilters.unregister(name: driver) }
        try Data("Y\n".utf8).write(to: dir.appendingPathComponent("f"))
        try touch("f", in: dir)
        let before = try snapshot(in: dir)
        let objects = try support.runGit(["count-objects", "-v"], in: dir)
        try await GitClient(workingDirectory: dir).refreshIndex(paths: ["f"])
        try expectUnchanged(before, in: dir)
        #expect(try support.runGit(["count-objects", "-v"], in: dir) == objects)
        #expect(try gitExit(["diff-index", "--quiet", "HEAD", "--", "f"], in: dir) == 1)
    }

    @Test("refresh leaves skipped entries alone", arguments: [
        "unmerged", "missing-entry", "missing-file", "skip-worktree", "assume-unchanged"
    ])
    func skippedEntry(kind: String) async throws {
        let dir = try support.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try touch("a.txt", in: dir)
        switch kind {
        case "unmerged":
            let oid = try support.runGit(["rev-parse", "HEAD:a.txt"], in: dir)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let records = "0 \(support.zeros)\ta.txt\n"
                + (1...3).map { "100644 \(oid) \($0)\ta.txt\n" }.joined()
            try support.runGit(["update-index", "--index-info"], in: dir, input: Data(records.utf8))
        case "missing-entry":
            try support.runGit(["rm", "--cached", "a.txt"], in: dir)
        case "missing-file":
            try FileManager.default.removeItem(at: dir.appendingPathComponent("a.txt"))
        default:
            try support.runGit(["update-index", "--\(kind)", "a.txt"], in: dir)
        }
        let before = try snapshot(in: dir)
        try await GitClient(workingDirectory: dir).refreshIndex(paths: ["a.txt", "untracked"])
        try expectUnchanged(before, in: dir)
        let entries = try support.runGit(["ls-files", "--stage"], in: dir)
        // Positional update-index operands also stage files; compare with the
        // refresh operation alone so the oracle does not resolve our conflict.
        _ = try support.runGit(["update-index", "-q", "--refresh"], in: dir, allowsFailure: true)
        #expect(try support.runGit(["ls-files", "--stage"], in: dir) == entries)
    }

    @Test("only requested paths are refreshed, honouring core.filemode", arguments: [true, false])
    func fileMode(trusted: Bool) async throws {
        let dir = try support.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try support.runGit(["config", "core.filemode", trusted ? "true" : "false"], in: dir)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("a.txt").path)
        try touch("a.txt", in: dir)
        try touch("b.txt", in: dir)
        let staged = try support.runGit(["ls-files", "-s"], in: dir)
        let before = try snapshot(in: dir)
        let client = GitClient(workingDirectory: dir)
        try await client.refreshIndex(paths: ["a.txt"])
        if trusted { try expectUnchanged(before, in: dir) }
        let changed = try await client.diffIndex(cached: false).map(\.destinationPath)
        #expect(changed == (trusted ? ["a.txt", "b.txt"] : ["b.txt"]))
        #expect(try support.runGit(["ls-files", "-s"], in: dir) == staged)
        #expect(try gitExit(["diff-index", "--quiet", "HEAD", "--", "a.txt"], in: dir) == (trusted ? 1 : 0))

        // Git also exposes this path-scoped stat-refresh primitive through add.
        try before.0.write(to: dir.appendingPathComponent(".git/index"))
        try support.runGit(["add", "--refresh", "--", "a.txt"], in: dir)
        let oracle = try support.runGit(["diff-index", "--name-only", "HEAD", "--"], in: dir)
            .split(separator: "\n").map(String.init)
        #expect(oracle == changed)
        #expect(try support.runGit(["ls-files", "-s"], in: dir) == staged)
    }

    @Test("a symlink refresh hashes the link text, not its target")
    func symlink() async throws {
        let dir = try support.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("a.txt"))
        try support.runGit(["add", "link"], in: dir)
        try support.runGit(["commit", "-m", "symlink"], in: dir)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("a.txt"))
        let client = GitClient(workingDirectory: dir)
        try await client.refreshIndex(paths: ["link"])
        #expect(try gitExit(["diff-index", "--quiet", "HEAD", "--", "link"], in: dir) == 0)
        #expect(try await client.diffIndex(cached: false).isEmpty)
    }

    @Test("all paths and the index are authorized before any filter reads", arguments: ["denied", "index", "f"])
    func sandboxDenial(denied: String) async throws {
        let dir = try filteredRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let driver = try driverName(in: dir)
        if denied == "f" { try support.runGit(["config", "core.ignorecase", "true"], in: dir) }
        try GitFilters.register(name: driver, GitFilter(clean: { _, _ in
            Issue.record("a sandbox denial must happen before the first content read")
            return nil
        }))
        defer { try? GitFilters.unregister(name: driver) }
        let sandbox = Sandbox(
            documentsDirectory: dir, downloadsDirectory: dir, libraryDirectory: dir,
            moviesDirectory: dir, musicDirectory: dir, picturesDirectory: dir,
            sharedPublicDirectory: dir, temporaryDirectory: dir, trashDirectory: dir,
            userDirectory: dir, cachesDirectory: dir, homeDirectory: dir,
            authorize: { url in
                if url.lastPathComponent == denied {
                    throw Sandbox.Denial(url: url, reason: "refresh denied")
                }
            })
        let shell = Shell(environment: Environment(workingDirectory: dir.path), sandbox: sandbox)
        let before = try snapshot(in: dir)
        await shell.withCurrent {
            let denial = await #expect(throws: Sandbox.Denial.self) {
                try await GitClient(workingDirectory: dir).refreshIndex(paths: [denied == "f" ? "F" : "f", "denied"])
            }
            #expect(denial?.url.lastPathComponent == denied)
        }
        try expectUnchanged(before, in: dir)
    }

    @Test("case aliases refresh using the index's stored spelling", arguments: [true, false])
    func caseAlias(ignoreCase: Bool) async throws {
        let dir = try support.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try support.runGit(["config", "core.ignorecase", ignoreCase ? "true" : "false"], in: dir)
        try touch("a.txt", in: dir)
        let driver = "refresh-case-" + UUID().uuidString
        try Data("a.txt filter=\(driver)\n".utf8).write(to: dir.appendingPathComponent(".git/info/attributes"))
        try GitFilters.register(name: driver, .buffered(clean: { source, _ in
            #expect(source.path == "a.txt")
            return nil
        }))
        defer { try? GitFilters.unregister(name: driver) }
        let staged = try support.runGit(["ls-files", "-s"], in: dir)
        let before = try snapshot(in: dir)
        try await GitClient(workingDirectory: dir).refreshIndex(paths: ["A.TXT"])
        #expect(try support.runGit(["ls-files", "-s"], in: dir) == staged)
        let status = try gitExit(["diff-index", "--quiet", "HEAD", "--", "a.txt"], in: dir)
        #expect(status == (ignoreCase ? 0 : 1))
        if ignoreCase {
            let refreshed = try snapshot(in: dir)
            try await GitClient(workingDirectory: dir).refreshIndex(paths: ["A.TXT", "a.txt"])
            try expectUnchanged(refreshed, in: dir)
            // Compare the refreshed canonical entry with Git's stat refresh,
            // which uses index paths, without staging positional operands.
            try before.0.write(to: dir.appendingPathComponent(".git/index"))
            try support.runGit(["update-index", "-q", "--refresh"], in: dir)
            #expect(try gitExit(["diff-index", "--quiet", "HEAD", "--", "a.txt"], in: dir) == status)
            #expect(try support.runGit(["ls-files", "-s"], in: dir) == staged)
        } else {
            try expectUnchanged(before, in: dir)
        }
    }

    @Test("core.symlinks=false refreshes a regular link placeholder using raw target text",
          arguments: [true, false], ["a.txt", "b.txt"])
    func symlinkPlaceholder(hasSymlinks: Bool, target: String) async throws {
        let dir = try support.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "a.txt")
        try support.runGit(["add", "link"], in: dir)
        try support.runGit(["commit", "-m", "symlink"], in: dir)
        try support.runGit(["config", "core.symlinks", hasSymlinks ? "true" : "false"], in: dir)
        try support.runGit(["config", "core.filemode", "true"], in: dir)
        try FileManager.default.removeItem(at: link)
        try Data(target.utf8).write(to: link)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: link.path)
        try touch("link", in: dir)

        let driver = "refresh-link-" + UUID().uuidString
        try Data("link filter=\(driver)\n".utf8).write(to: dir.appendingPathComponent(".git/info/attributes"))
        try GitFilters.register(name: driver, GitFilter(clean: { _, _ in
            Issue.record("an indexed symlink must hash its raw target text without a clean filter")
            return nil
        }))
        defer { try? GitFilters.unregister(name: driver) }
        let staged = try support.runGit(["ls-files", "-s"], in: dir)
        let before = try snapshot(in: dir)
        let matches = !hasSymlinks && target == "a.txt"
        #expect(try gitExit(["diff-index", "--quiet", "HEAD", "--", "link"], in: dir) == 1)
        try await GitClient(workingDirectory: dir).refreshIndex(paths: ["link"])
        if !matches { try expectUnchanged(before, in: dir) }
        let status = try gitExit(["diff-index", "--quiet", "HEAD", "--", "link"], in: dir)
        #expect(status == (matches ? 0 : 1))
        #expect(try support.runGit(["ls-files", "-s"], in: dir) == staged)
        _ = try support.runGit(["update-index", "-q", "--refresh"], in: dir, allowsFailure: true)
        #expect(try gitExit(["diff-index", "--quiet", "HEAD", "--", "link"], in: dir) == status)
        #expect(try support.runGit(["ls-files", "-s"], in: dir) == staged)
    }

    private func filteredRepo() throws -> URL {
        let dir = try support.makeRepo()
        try Data("pointer(X)\n".utf8).write(to: dir.appendingPathComponent("f"))
        try support.runGit(["add", "f"], in: dir)
        try support.runGit(["commit", "-m", "pointer"], in: dir)
        let driver = "refresh-" + UUID().uuidString
        try Data("f filter=\(driver)\n".utf8).write(to: dir.appendingPathComponent(".git/info/attributes"))
        try support.runGit(["config", "filter.\(driver).clean", "sed 's/.*/pointer(&)/'"], in: dir)
        try support.runGit(["config", "test.refresh-driver", driver], in: dir)
        try Data("X\n".utf8).write(to: dir.appendingPathComponent("f"))
        try touch("f", in: dir)
        return dir
    }

    private func driverName(in dir: URL) throws -> String {
        try support.runGit(["config", "test.refresh-driver"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func touch(_ name: String, in dir: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: past], ofItemAtPath: dir.appendingPathComponent(name).path)
    }

    private func snapshot(in dir: URL) throws -> (Data, Date, UInt64) {
        let index = dir.appendingPathComponent(".git/index")
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: index.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: index.path)
        return (try Data(contentsOf: index), try #require(attributes[.modificationDate] as? Date),
                try #require(attributes[.systemFileNumber] as? UInt64))
    }

    private func expectUnchanged(_ before: (Data, Date, UInt64), in dir: URL) throws {
        let index = dir.appendingPathComponent(".git/index")
        let attributes = try FileManager.default.attributesOfItem(atPath: index.path)
        #expect(try Data(contentsOf: index) == before.0)
        #expect(attributes[.modificationDate] as? Date == before.1)
        #expect(attributes[.systemFileNumber] as? UInt64 == before.2)
    }

    private func gitExit(_ args: [String], in dir: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
#endif
