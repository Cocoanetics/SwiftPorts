#if os(macOS) || os(Linux)
import Foundation
import Testing

/// Both implementations operate on the same repository in separate processes.
struct LFSFilterOracleFixture {
    let host = IsolatedLFSHost()
    let executable: String
    let directory: URL

    init() throws {
        executable = try LFSFilterProcess.builtGit()
        directory = host.root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try system(["init", "-q", "-b", "main"])
        for (key, value) in [("user.name", "Filter"), ("user.email", "filter@example.com")]
            + LFSFilterFixture.commands {
            try system(["config", key, value])
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: host.root) }

    @discardableResult
    func system(_ arguments: [String]) throws -> String {
        let result = try run(arguments, reference: true)
        #expect(result.status == 0, "\(arguments): \(result.stderr)")
        return result.stdout
    }

    func run(
        _ arguments: [String], reference: Bool = false, environment: [String: String] = [:], cwd: URL? = nil
    ) throws -> (stdout: String, stderr: String, status: Int32) {
        try LFSFilterProcess.run(reference ? "/usr/bin/env" : executable,
            (reference ? ["git"] : []) + arguments, host: host, cwd: cwd ?? directory, environment: environment)
    }

    func seed(_ data: Data) throws {
        try Data("*.lfs filter=lfs -text\n".utf8).write(to: directory.appendingPathComponent(".gitattributes"))
        try data.write(to: directory.appendingPathComponent("a.lfs"))
        let result = try run(["add", ".gitattributes", "a.lfs"])
        #expect(result.status == 0, "\(result.stderr)")
        try system(["-c", "core.hooksPath=/dev/null", "commit", "-qm", "content"])
    }

    func configure(_ values: [String: String]) throws {
        for (key, value) in values { try system(["config", key, value]) }
    }

    func checkout(reference: Bool, environment: [String: String] = [:]) throws
        -> (bytes: Data?, stderr: String, status: Int32) {
        let file = directory.appendingPathComponent("a.lfs")
        try? FileManager.default.removeItem(at: file)
        let result = try run(["checkout", "--", "a.lfs"], reference: reference, environment: environment)
        return (FileManager.default.contents(atPath: file.path), result.stderr, result.status)
    }
}
#endif
