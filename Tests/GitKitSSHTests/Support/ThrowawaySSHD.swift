#if os(macOS) || os(Linux)
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Spawns a throwaway, unprivileged `sshd(8)` on an ephemeral port with a disposable host key and
/// a single `authorized_keys` entry — the end-to-end oracle issue #113 names for `GitKitSSHTests`.
/// `Process`-based, which is otherwise against this repo's conventions (AGENTS.md: "No `Process`
/// shellouts anywhere except in clearly-marked Mac/Linux-only paths"); this is exactly that
/// exception, and test-only. Mirrors `Tests/SSHKitTests/Support/ThrowawaySSHD.swift` — duplicated
/// rather than shared, since the two test targets can't see each other's internal sources.
final class ThrowawaySSHD {
    let port: Int
    let hostPublicKeyPath: String
    private let process: Process
    private let directory: URL

    private init(port: Int, hostPublicKeyPath: String, process: Process, directory: URL) {
        self.port = port
        self.hostPublicKeyPath = hostPublicKeyPath
        self.process = process
        self.directory = directory
    }

    /// `nil` if no system `sshd`/`ssh-keygen` is available, so tests can skip gracefully instead
    /// of failing on a CI image that doesn't ship one.
    static func start(authorizingPublicKeyPath: String) async throws -> ThrowawaySSHD? {
        guard
            let sshdPath = Self.findExecutable("sshd", extraPaths: ["/usr/sbin/sshd"]),
            let keygenPath = Self.findExecutable("ssh-keygen", extraPaths: ["/usr/bin/ssh-keygen"])
        else {
            return nil
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitkitssh-throwaway-sshd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let hostKeyPath = directory.appendingPathComponent("host_key").path
        try Self.run(keygenPath, ["-t", "ed25519", "-N", "", "-f", hostKeyPath, "-q"])

        let authorizedKeysPath = directory.appendingPathComponent("authorized_keys").path
        let authorizingKey = try String(contentsOfFile: authorizingPublicKeyPath, encoding: .utf8)
        try authorizingKey.write(toFile: authorizedKeysPath, atomically: true, encoding: .utf8)

        guard let port = Self.findEphemeralPort() else {
            return nil
        }

        let configPath = directory.appendingPathComponent("sshd_config").path
        let config = """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(hostKeyPath)
            AuthorizedKeysFile \(authorizedKeysPath)
            PidFile \(directory.appendingPathComponent("sshd.pid").path)
            UsePAM no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            PubkeyAuthentication yes
            StrictModes no
            LogLevel ERROR
            """
        try config.write(toFile: configPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshdPath)
        process.arguments = ["-f", configPath, "-D", "-e"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Give sshd a moment to bind and start listening before the first connection attempt.
        try await Task.sleep(nanoseconds: 300_000_000)

        guard process.isRunning else {
            return nil
        }

        return ThrowawaySSHD(
            port: port,
            hostPublicKeyPath: hostKeyPath + ".pub",
            process: process,
            directory: directory
        )
    }

    func stop() {
        if self.process.isRunning {
            self.process.terminate()
            Self.waitForExit(self.process)
        }
        try? FileManager.default.removeItem(at: self.directory)
    }

    /// Waits for `process` to exit by polling `isRunning` rather than calling `waitUntilExit()`.
    /// Called from a Swift concurrency thread, `waitUntilExit()` can block forever after the
    /// child has already exited and been reaped (a lost run-loop wakeup, the same hang as
    /// MissionControl #452); it wedged this suite in `stop()`. Escalates to SIGKILL after
    /// `timeout` so a stuck `sshd` can't hang the run either.
    static func waitForExit(_ process: Process, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        let killDeadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < killDeadline {
            usleep(10_000)
        }
    }

    private static func run(_ executablePath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        waitForExit(process, timeout: 60)
    }

    private static func findExecutable(_ name: String, extraPaths: [String]) -> String? {
        for path in extraPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [name]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        guard (try? which.run()) != nil else {
            return nil
        }
        waitForExit(which)
        guard which.terminationStatus == 0 else {
            return nil
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Binds a TCP socket to port 0 to let the kernel pick a free port, then releases it — a brief
    /// race window exists before `sshd` binds the same port, acceptable for a throwaway test fixture.
    private static func findEphemeralPort() -> Int? {
        #if canImport(Glibc)
        // Glibc types `SOCK_STREAM` as `__socket_type`, not `Int32` like Darwin's macro constant.
        let socketType = Int32(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        let socketFD = socket(AF_INET, socketType, 0)
        guard socketFD >= 0 else {
            return nil
        }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            return nil
        }

        var assignedAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getNameResult = withUnsafeMutablePointer(to: &assignedAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(socketFD, sockaddrPointer, &length)
            }
        }
        guard getNameResult == 0 else {
            return nil
        }

        return Int(UInt16(bigEndian: assignedAddress.sin_port))
    }
}
#endif
