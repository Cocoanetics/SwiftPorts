#if os(macOS) || os(Linux)
import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// The oracle is a subprocess, not our HTTP transport. File-backed streams
/// avoid stdin/stderr pipe cycles; bounded polling also avoids an unbounded
/// Foundation waitUntilExit/run-loop wait after the child has already exited.
enum LFSOracleProcess {
    static func run(
        _ process: Process, input: Data? = nil, directory: URL, timeout: TimeInterval = 60
    ) throws -> (out: Data, err: String, status: Int32) {
        let capture = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: capture) }
        let stdin = capture.appendingPathComponent("stdin")
        let stdout = capture.appendingPathComponent("stdout")
        let stderr = capture.appendingPathComponent("stderr")
        try (input ?? Data()).write(to: stdin)
        try Data().write(to: stdout)
        try Data().write(to: stderr)
        let source = try FileHandle(forReadingFrom: stdin)
        defer { try? source.close() }
        let out = try FileHandle(forWritingTo: stdout)
        defer { try? out.close() }
        let err = try FileHandle(forWritingTo: stderr)
        defer { try? err.close() }
        process.standardInput = source
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = ContinuousClock.now + .seconds(timeout)
        while process.isRunning, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.005) }
        if process.isRunning {
            // Give git a chance to forward termination to its git-lfs child.
            process.terminate()
            let grace = ContinuousClock.now + .seconds(0.2)
            while process.isRunning, ContinuousClock.now < grace { Thread.sleep(forTimeInterval: 0.005) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            let reapDeadline = ContinuousClock.now + .seconds(2)
            while process.isRunning, ContinuousClock.now < reapDeadline { Thread.sleep(forTimeInterval: 0.005) }
            let message = (try? String(contentsOf: stderr, encoding: .utf8)) ?? ""
            throw LFSOracleFailure(description:
                "Oracle subprocess timed out after \(timeout)s: \(process.arguments ?? [])\n\(message)")
        }
        return (try Data(contentsOf: stdout),
                String(decoding: try Data(contentsOf: stderr), as: UTF8.self), process.terminationStatus)
    }
}
#endif
