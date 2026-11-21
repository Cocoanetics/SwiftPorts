#if os(macOS) || os(Linux)
import Foundation
import Testing
#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// File-backed output prevents pipe-capacity deadlocks; every child has a hard deadline.
enum LFSFilterProcess {
    private final class BundleMarker: NSObject {}

    static func builtGit() throws -> String {
        #if os(macOS)
        var directory = Bundle(for: BundleMarker.self).bundleURL
        #else
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        #endif
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("git").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw LFSOracleFailure(description: "Build the git executable alongside the tests")
    }

    static func run(
        _ executable: String, _ arguments: [String], host: IsolatedLFSHost, cwd: URL,
        environment: [String: String] = [:], timeout: TimeInterval = 20
    ) throws -> (stdout: String, stderr: String, status: Int32) {
        let prefix = host.root.appendingPathComponent(UUID().uuidString)
        let stdout = prefix.appendingPathExtension("out"), stderr = prefix.appendingPathExtension("err")
        for file in [stdout, stderr] {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        defer {
            try? FileManager.default.removeItem(at: stdout)
            try? FileManager.default.removeItem(at: stderr)
        }
        let out = try FileHandle(forWritingTo: stdout), err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = host.variables.merging([
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"
        ]) { _, value in value }.merging(environment) { _, value in value }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        return (try String(contentsOf: stdout, encoding: .utf8),
                try String(contentsOf: stderr, encoding: .utf8), process.terminationStatus)
    }
}
#endif
