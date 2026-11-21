#if os(macOS) || os(Linux) || os(Windows)
import Foundation
import Testing

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

    private static let command: (executable: URL, arguments: [String])? = {
        #if os(Windows)
        let windows = true
        #else
        let windows = false
        #endif
        guard let command = pythonCommand(environment: ProcessInfo.processInfo.environment, windows: windows)
        else { return nil }
        // A launcher can exist without a Python 3 installation.
        let probe = Process()
        probe.executableURL = command.executable
        probe.arguments = command.arguments + ["--version"]
        probe.standardInput = FileHandle.nullDevice
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do { try probe.run() } catch { return nil }
        probe.waitUntilExit()
        return probe.terminationStatus == 0 ? command : nil
    }()

    static var isAvailable: Bool { command != nil }
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
        let command = try #require(Self.command, Self.unavailableReason)
        let script = try #require(Bundle.module.url(forResource: "LFSUploadServer", withExtension: "py",
                                                    subdirectory: "Fixtures"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ready = directory.appendingPathComponent("ready.txt")
        let log = directory.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        output = try FileHandle(forWritingTo: log)
        process.executableURL = command.executable
        process.arguments = command.arguments + ["-u", script.path, ready.path]
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
            process.waitUntilExit()
        }
        try? output?.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
