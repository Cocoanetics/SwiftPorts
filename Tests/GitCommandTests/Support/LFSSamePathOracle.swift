// One repository, read by system `git lfs` and `GitCommand` at the same path.
// #206 reuses this helper. It does not call `LFSCommandFixture.compare` and it
// does not rewrite paths, sort lines, or reformat JSON.
#if os(macOS) || os(Linux)
import Foundation
import ShellKit
import ShellCommandKit
import Testing
import GitCommand
import SwiftGit

struct LFSSamePathOracle {
    struct Output: Equatable {
        var stdout: String
        var stderr: String
        var status: Int32
    }

    let root: URL
    let home: URL
    let xdgConfigHome: URL
    let globalConfig: URL
    let systemConfig: URL

    /// Whether the pinned git-lfs 3.7.1 reference is the `git lfs` on `PATH`.
    static let isAvailable: Bool = {
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
            guard process.terminationStatus == 0 else { return false }
            return isReferenceRelease(String(decoding: data, as: UTF8.self))
        } catch {
            return false
        }
    }()

    /// The raw env oracle's rule: the first token of `git lfs version` is `git-lfs/3.7.1`.
    static func isReferenceRelease(_ output: String) -> Bool {
        output.split(whereSeparator: { $0.isWhitespace }).first == "git-lfs/3.7.1"
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LFSSame-\(UUID().uuidString.prefix(8))")
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        xdgConfigHome = root.appendingPathComponent("xdg", isDirectory: true)
        globalConfig = home.appendingPathComponent(".gitconfig")
        systemConfig = root.appendingPathComponent("system.gitconfig")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xdgConfigHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("tmp", isDirectory: true), withIntermediateDirectories: true)
        let identity = """
        [user]
        \tname = LFS Oracle
        \temail = lfs@example.com
        [core]
        \tautocrlf = false

        """
        try identity.write(to: globalConfig, atomically: false, encoding: .utf8)
        try Data().write(to: systemConfig)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// `git init` and local `git lfs install`, so `track` / `add` / `commit` store pointers.
    func repository(_ name: String, bare: Bool = false) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var arguments = ["init", "-q", "-b", "main"]
        if bare { arguments.append("--bare") }
        try git(arguments, in: directory)
        if !bare { try git(["lfs", "install", "--local"], in: directory) }
        return directory
    }

    func bareClone(of source: URL, named name: String) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try git(["clone", "--bare", "-q", source.path, directory.path], in: root)
        return directory
    }

    func write(_ path: String, _ data: Data, in directory: URL) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func write(_ path: String, _ text: String, in directory: URL) throws {
        try write(path, Data(text.utf8), in: directory)
    }

    func track(_ patterns: [String], in directory: URL) throws {
        try git(["lfs", "track"] + patterns, in: directory)
    }

    func add(_ paths: [String], in directory: URL) throws {
        try git(["add", "--"] + paths, in: directory)
    }

    func commit(_ message: String, in directory: URL) throws {
        try git(["commit", "-q", "-m", message], in: directory)
    }

    /// Stores blob bytes with `hash-object` and `update-index`, so the clean filter cannot rewrite them.
    func addRaw(_ data: Data, path: String, in directory: URL) throws {
        let hashed = try git(["hash-object", "-w", "--stdin"], in: directory, input: data)
        let oid = hashed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["update-index", "--add", "--cacheinfo", "100644,\(oid),\(path)"], in: directory)
    }

    /// System `git lfs` and `GitCommand` at `directory`, after restoring config, the index,
    /// and worktree metadata so the second read sees the same repository as the first.
    @discardableResult
    func compare(_ arguments: [String], in directory: URL) async throws -> Output {
        let snapshot = try capture(from: directory)
        let expected = try run(["lfs"] + arguments, in: directory)
        try restore(snapshot)
        let actual = try await command(arguments, in: directory)
        try restore(snapshot)
        let label = arguments.joined(separator: " ")
        #expect(Self.normalize(actual.stdout) == Self.normalize(expected.stdout), "stdout \(label)")
        #expect(Self.normalize(actual.stderr) == Self.normalize(expected.stderr), "stderr \(label)")
        #expect(actual.status == expected.status, "status \(label)")
        return actual
    }

    /// Replaces a `git-lfs/<digits>` line and a git version line, and nothing else.
    static func normalize(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { piece in
            let line = String(piece)
            let suffix = line.dropFirst("git-lfs/".count)
            let versionLine = line.hasPrefix("git-lfs/") && suffix.first?.isNumber == true
            if versionLine || line.hasPrefix("git version ") || line == PortVersion.gitLine {
                return "<version>"
            }
            return line
        }.joined(separator: "\n")
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL, input: Data = Data()) throws -> Output {
        let result = try run(arguments, in: directory, input: input)
        #expect(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.stderr)")
        return result
    }

    private func commandEnvironment() -> [String: String] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        return ["PATH": path, "TMPDIR": temporary, "LC_ALL": "C",
                "HOME": home.path, "XDG_CONFIG_HOME": xdgConfigHome.path,
                "GIT_CONFIG_GLOBAL": globalConfig.path, "GIT_CONFIG_SYSTEM": systemConfig.path]
    }

    private var sandbox: Sandbox {
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        return Sandbox(
            documentsDirectory: temporary, downloadsDirectory: temporary, libraryDirectory: temporary,
            moviesDirectory: temporary, musicDirectory: temporary, picturesDirectory: temporary,
            sharedPublicDirectory: temporary, temporaryDirectory: temporary, trashDirectory: temporary,
            userDirectory: temporary, cachesDirectory: temporary, homeDirectory: home,
            authorize: { _ in })
    }

    /// System `git`, whatever its exit status.
    func run(_ arguments: [String], in directory: URL, input: Data = Data()) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.environment = commandEnvironment()
        let stdin = Pipe(), out = Pipe(), err = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = err
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(stdout: String(decoding: stdout, as: UTF8.self),
                      stderr: String(decoding: stderr, as: UTF8.self), status: process.terminationStatus)
    }

    private func command(_ arguments: [String], in directory: URL) async throws -> Output {
        try await port(["lfs"] + arguments, in: directory)
    }

    /// `GitCommand` for `git <arguments>`, in the same environment as system git.
    func port(_ arguments: [String], in directory: URL) async throws -> Output {
        let out = OutputSink(), err = OutputSink()
        let shell = Shell(stdin: InputSource.data(Data()), stdout: out, stderr: err,
                          environment: Environment(variables: commandEnvironment(),
                                                   workingDirectory: directory.path))
        shell.sandbox = sandbox
        let status = try await shell.withCurrent {
            try await Shell.parsableCommand(GitCommand.self).run(["git"] + arguments)
        }
        out.finish()
        err.finish()
        return Output(stdout: await out.readAllString(), stderr: await err.readAllString(), status: status.code)
    }

    private struct Blob {
        var path: String
        var data: Data?
    }

    private struct FileStamp {
        var path: String
        var modified: Date
        var permissions: Int
        var isSymbolicLink: Bool
    }

    private struct Snapshot {
        var blobs: [Blob]
        var stamps: [FileStamp]
        var workTree: URL?
    }

    private func capture(from cwd: URL) throws -> Snapshot {
        let probed = try run(["rev-parse", "--is-bare-repository"], in: cwd)
        guard probed.status == 0 else { return Snapshot(blobs: [], stamps: [], workTree: nil) }
        let gitDir = URL(fileURLWithPath: try run(["rev-parse", "--absolute-git-dir"], in: cwd).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines))
        let paths = [gitDir.appendingPathComponent("config").path, gitDir.appendingPathComponent("index").path,
                     globalConfig.path, systemConfig.path]
        let blobs = paths.map { Blob(path: $0, data: FileManager.default.contents(atPath: $0)) }
        let bare = probed.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        guard !bare else { return Snapshot(blobs: blobs, stamps: [], workTree: nil) }
        let top = try run(["rev-parse", "--show-toplevel"], in: cwd)
        guard top.status == 0 else { return Snapshot(blobs: blobs, stamps: [], workTree: nil) }
        let work = URL(fileURLWithPath: top.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        return Snapshot(blobs: blobs, stamps: stamps(in: work), workTree: work)
    }

    private func restore(_ snapshot: Snapshot) throws {
        for blob in snapshot.blobs {
            if let data = blob.data {
                try data.write(to: URL(fileURLWithPath: blob.path))
            } else if FileManager.default.fileExists(atPath: blob.path) {
                try FileManager.default.removeItem(atPath: blob.path)
            }
        }
        if let work = snapshot.workTree {
            let original = Set(snapshot.stamps.map(\.path))
            for path in filePaths(in: work) where !original.contains(path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
        for stamp in snapshot.stamps where !stamp.isSymbolicLink {
            try FileManager.default.setAttributes(
                [.modificationDate: stamp.modified, .posixPermissions: stamp.permissions],
                ofItemAtPath: stamp.path)
        }
    }

    private func stamps(in root: URL) -> [FileStamp] {
        filePaths(in: root).compactMap { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date,
                  let permissions = attributes[.posixPermissions] as? NSNumber else { return nil }
            let isSymbolicLink = attributes[.type] as? FileAttributeType == .typeSymbolicLink
            return FileStamp(path: path, modified: modified, permissions: permissions.intValue,
                             isSymbolicLink: isSymbolicLink)
        }
    }

    private func filePaths(in root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var paths: [String] = []
        while let item = enumerator.nextObject() as? URL {
            if item.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            let directory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !directory { paths.append(item.path) }
        }
        return paths
    }
}
#endif
