#if os(macOS) || os(Linux) || os(Windows)
import Foundation
import Testing
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// Test-only subprocess control: bypass NIO on Windows as well as macOS/Linux.
/// stdout/stderr go to a file so a full diagnostic pipe cannot stall the server.
final class LFSPlainUploadServer {
    private let process = Process()
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var output: FileHandle?
    private(set) var endpoint: URL?

    static func pythonCommand(
        environment: [String: String], windows: Bool,
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) -> (executable: URL, arguments: [String])? {
        if windows, let directory = environment.first(where: {
            $0.key.caseInsensitiveCompare("pythonLocation") == .orderedSame
        })?.value {
            let executable = URL(fileURLWithPath: directory).appendingPathComponent("python.exe")
            if isExecutable(executable) { return (executable, []) }
        }
        let path = environment["PATH"] ?? (windows ? environment.first {
            $0.key.caseInsensitiveCompare("PATH") == .orderedSame
        }?.value : nil) ?? ""
        let paths = path.split(separator: windows ? ";" : ":")
        // Windows' python.exe may be a Store alias. Prefer the runner's setup
        // directory, then the Python launcher with an explicit Python 3 version.
        var candidates = paths.map {
            URL(fileURLWithPath: String($0)).appendingPathComponent(windows ? "py.exe" : "python3")
        }
        if windows, let systemRoot = environment["SystemRoot"] {
            candidates.append(URL(fileURLWithPath: systemRoot).appendingPathComponent("py.exe"))
        }
        guard let executable = candidates.first(where: isExecutable) else { return nil }
        return (executable, windows ? ["-3"] : [])
    }

    /// The interpreter itself, resolved through `pythonCommand`. A launcher can
    /// exist without Python 3, and `py.exe` runs python.exe as a child that
    /// survives `terminate()`, so the server must not start through it.
    private static let interpreter: URL? = {
        #if os(Windows)
        let windows = true
        #else
        let windows = false
        #endif
        guard let command = pythonCommand(environment: ProcessInfo.processInfo.environment, windows: windows)
        else { return nil }
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: result.path, contents: nil),
              let output = try? FileHandle(forWritingTo: result) else { return nil }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: result)
        }
        let probe = Process()
        probe.executableURL = command.executable
        probe.arguments = command.arguments + ["-c", "import sys; print(sys.executable)"]
        probe.standardInput = FileHandle.nullDevice
        probe.standardOutput = output
        probe.standardError = FileHandle.nullDevice
        do { try probe.run() } catch { return nil }
        guard waitForExit(probe, timeout: 30) else {
            probe.terminate()
            return nil
        }
        guard probe.terminationStatus == 0,
              let path = (try? String(contentsOf: result, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }()

    static var isAvailable: Bool { interpreter != nil }
    static let unavailableReason: Comment = "Python 3 is unavailable (Windows requires pythonLocation or py -3)"

    static func start() async throws -> LFSPlainUploadServer {
        let server = LFSPlainUploadServer()
        do {
            try await server.launch()
            return server
        } catch {
            server.stop()
            throw error
        }
    }

    private func launch() async throws {
        let interpreter = try #require(Self.interpreter, Self.unavailableReason)
        let script = try #require(Bundle.module.url(forResource: "LFSUploadServer", withExtension: "py",
                                                    subdirectory: "Fixtures"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ready = directory.appendingPathComponent("ready.txt")
        let log = directory.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        output = try FileHandle(forWritingTo: log)
        process.executableURL = interpreter
        process.arguments = ["-u", script.path, ready.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, process.isRunning {
            if let text = try? String(contentsOf: ready, encoding: .utf8), let url = URL(string: text) {
                endpoint = url
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Python PUT server did not start: \(diagnostics())")
        throw URLError(.cannotConnectToHost)
    }

    func diagnostics() -> String {
        (try? String(contentsOf: directory.appendingPathComponent("server.log"), encoding: .utf8)) ?? ""
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            if !Self.waitForExit(process, timeout: 5) {
                #if !os(Windows)
                // terminate() is a no-op if the child still blocks SIGTERM.
                kill(process.processIdentifier, SIGKILL)
                #endif
                _ = Self.waitForExit(process, timeout: 5)
            }
        }
        try? output?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Polls `isRunning`: Foundation's `waitUntilExit()` has no deadline and,
    /// on Linux, can miss its run-loop wakeup when called from a test task.
    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while process.isRunning, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return !process.isRunning
    }
}
#endif
