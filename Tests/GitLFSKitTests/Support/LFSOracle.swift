// The system `git` and `git-lfs` as the oracle the LFS suites compare
// against, run in an isolated HOME / XDG / global config
// (`IsolatedLFSHost`) so a developer's own `lfs.*` or filter settings
// can't reach a test.
#if os(macOS) || os(Linux)
import Foundation

struct LFSOracle: Sendable {
    /// The isolated configuration both the oracle and ours run under.
    let host = IsolatedLFSHost()

    var root: URL { host.root }
    var variables: [String: String] { host.variables }

    /// Whether `git lfs version` runs; the oracle suites are skipped otherwise.
    static let isAvailable: Bool = {
        (try? LFSOracle().run(["lfs", "version"], in: FileManager.default.temporaryDirectory).status) == 0
    }()

    /// `git <args>` in `dir`, with `input` on stdin: its stdout bytes,
    /// stderr text and exit status.
    @discardableResult
    func run(_ args: [String], in dir: URL, input: Data? = nil) throws -> (out: Data, err: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir
        let inherited = ProcessInfo.processInfo.environment.filter { name, _ in
            name != "GIT_CONFIG_COUNT" && name != "GIT_CONFIG_PARAMETERS"
                && !name.hasPrefix("GIT_CONFIG_KEY_") && !name.hasPrefix("GIT_CONFIG_VALUE_")
                && !name.hasPrefix("GIT_LFS_")
        }
        process.environment = inherited.merging(variables) { _, new in new }
        let stdin = Pipe(), out = Pipe(), err = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = err
        try process.run()
        stdin.fileHandleForWriting.write(input ?? Data())
        try stdin.fileHandleForWriting.close()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (output, message, process.terminationStatus)
    }

    /// `git <args>` that must succeed; its stdout, trimmed.
    @discardableResult
    func git(_ args: [String], in dir: URL) throws -> String {
        let result = try run(args, in: dir)
        guard result.status == 0 else {
            throw LFSOracleFailure(description: "git \(args.joined(separator: " ")): \(result.err)")
        }
        return String(decoding: result.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `git lfs env`'s `Key=Value` lines in `dir`.
    func lfsEnvironment(in dir: URL) throws -> [String: String] {
        var values: [String: String] = [:]
        for line in try git(["lfs", "env"], in: dir).split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return values
    }

    /// A fresh directory under the oracle's root.
    func makeDirectory(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

#endif
