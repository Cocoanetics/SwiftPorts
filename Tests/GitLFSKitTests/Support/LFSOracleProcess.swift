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

    /// Runs `process` with stdout on a new pseudo-terminal `columns` wide and
    /// stdin / stderr on the null device; returns what the terminal received
    /// (the line discipline turns `\n` into `\r\n`) once every writer closed it.
    static func runInTerminal(
        _ process: Process, columns: Int, timeout: TimeInterval = 60
    ) throws -> (out: Data, status: Int32) {
        let controller = open("/dev/ptmx", O_RDWR | O_NOCTTY)
        guard controller >= 0 else { throw LFSOracleFailure(description: "open /dev/ptmx: \(errno)") }
        defer { close(controller) }
        guard pseudoTerminalCall("grantpt", controller) == 0, pseudoTerminalCall("unlockpt", controller) == 0,
              let name = pseudoTerminalName(controller) else {
            throw LFSOracleFailure(description: "pseudo-terminal setup: \(errno)")
        }
        let device = open(name, O_RDWR | O_NOCTTY)
        guard device >= 0 else { throw LFSOracleFailure(description: "open \(String(cString: name)): \(errno)") }
        var size = winsize()
        size.ws_col = UInt16(columns)
        size.ws_row = 24
        #if os(Linux)
        _ = ioctl(device, UInt(TIOCSWINSZ), &size)
        #else
        _ = ioctl(device, TIOCSWINSZ, &size)
        #endif
        let terminal = FileHandle(fileDescriptor: device, closeOnDealloc: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = terminal
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? terminal.close()
            throw error
        }
        try terminal.close()

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            var poller = pollfd(fd: controller, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) >= 0 else { break }
            if poller.revents == 0 { continue }
            let count = read(controller, &buffer, buffer.count)
            // Once every copy of the terminal device is closed, the controller reads 0 or EIO.
            if count <= 0 { break }
            output.append(contentsOf: buffer[0..<count])
        }
        while process.isRunning, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.005) }
        if process.isRunning {
            process.terminate()
            throw LFSOracleFailure(description: "Oracle terminal subprocess timed out: \(process.arguments ?? [])")
        }
        return (output, process.terminationStatus)
    }

    // Glibc's Swift module hides the XSI pseudo-terminal calls (`_XOPEN_SOURCE`),
    // so both platforms look them up in the C library.
    private static func pseudoTerminalCall(_ name: String, _ descriptor: Int32) -> Int32 {
        typealias Call = @convention(c) (Int32) -> Int32
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), name) else { return -1 }
        return unsafeBitCast(symbol, to: Call.self)(descriptor)
    }

    private static func pseudoTerminalName(_ descriptor: Int32) -> UnsafeMutablePointer<CChar>? {
        typealias Call = @convention(c) (Int32) -> UnsafeMutablePointer<CChar>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "ptsname") else { return nil }
        return unsafeBitCast(symbol, to: Call.self)(descriptor)
    }
}
#endif
