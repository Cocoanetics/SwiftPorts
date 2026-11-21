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

    static func pythonExecutable(
        environment: [String: String], windows: Bool,
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) -> URL? {
        let path = environment["PATH"] ?? (windows ? environment.first {
            $0.key.caseInsensitiveCompare("PATH") == .orderedSame
        }?.value : nil) ?? ""
        let names = windows ? ["python.exe", "python3.exe"] : ["python3"]
        let paths = path.split(separator: windows ? ";" : ":")
        return names.lazy.flatMap { name in
            paths.map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
        }.first(where: isExecutable)
    }

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
        #if os(Windows)
        let windows = true
        #else
        let windows = false
        #endif
        let executable = try #require(Self.pythonExecutable(
            environment: ProcessInfo.processInfo.environment, windows: windows),
                                      "Python 3 is required for the independent Windows upload probe")
        let script = try #require(Bundle.module.url(forResource: "LFSUploadServer", withExtension: "py",
                                                    subdirectory: "Fixtures"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ready = directory.appendingPathComponent("ready.txt")
        let log = directory.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        output = try FileHandle(forWritingTo: log)
        process.executableURL = executable
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
            process.waitUntilExit()
        }
        try? output?.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
