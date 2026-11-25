// `git -C` / `git -c` (issue #260): one invocation, run by system git, by the
// built `git` executable and by the `git` command `SwiftPortsCommands`
// registers, on the same paths with the same environment and the same
// starting state.
#if os(macOS) || os(Linux)
import Foundation
import ShellKit
import SwiftPortsCommands
import Testing

/// Anchors `Bundle(for:)` on the test bundle, whose directory also holds the
/// products `swift build` built.
private final class GitInvocationOracleBundleToken {}

struct GitInvocationOracle {
    struct Output: Equatable, CustomStringConvertible {
        var stdout: String
        var stderr: String
        var status: Int32

        var description: String { "status \(status)\nstdout:\n\(stdout)stderr:\n\(stderr)" }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The two entry paths of the port.
    enum Entry: String, CaseIterable, CustomStringConvertible {
        case standalone
        case embedded

        var description: String { rawValue }
    }

    let root: URL
    let home: URL
    let xdgConfigHome: URL
    let globalConfig: URL

    /// The built `git` executable, next to the test bundle (`swift build`
    /// builds every product before `swift test` runs).
    static let standaloneBinary: URL? = {
        var directories: [URL] = [Bundle(for: GitInvocationOracleBundleToken.self).bundleURL
            .deletingLastPathComponent()]
        directories.append(Bundle.main.bundleURL)
        if let first = CommandLine.arguments.first {
            directories.append(URL(fileURLWithPath: first).deletingLastPathComponent())
        }
        for argument in CommandLine.arguments where argument.hasSuffix(".xctest") {
            directories.append(URL(fileURLWithPath: argument).deletingLastPathComponent())
        }
        return directories.map { $0.appendingPathComponent("git") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    /// The `git` command a host shell installs.
    static var registeredCommand: Command? {
        SwiftPortsCommands.argumentParserCommands.first { $0.name == "git" }
    }

    /// A fresh root, physical (no `/var` → `/private/var` link left in it,
    /// as git's working directory never has one), with a home whose global
    /// config is `globalConfig`.
    init(globalConfig config: String = "") throws {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("Invocation-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        guard let physical = realpath(created.path, nil) else {
            throw Failure(description: "realpath \(created.path)")
        }
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        xdgConfigHome = root.appendingPathComponent("xdg", isDirectory: true)
        globalConfig = home.appendingPathComponent(".gitconfig")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xdgConfigHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("tmp", isDirectory: true), withIntermediateDirectories: true)
        try config.write(to: globalConfig, atomically: false, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// The environment every run gets, `extra` over it.
    ///
    /// `GIT_TEST_MAINT_AUTO_DETACH=false` keeps system git's auto
    /// maintenance (after a commit, say) in the foreground: detached, it holds
    /// `objects/maintenance.lock` after git has returned, while the fixture
    /// is copied. It is read only when no `*.autoDetach` is configured, and
    /// it is no config entry, so no `config` output shows it.
    func environment(_ extra: [String: String] = [:]) -> [String: String] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        var environment = ["PATH": path, "TMPDIR": temporary, "LC_ALL": "C",
                           "HOME": home.path, "XDG_CONFIG_HOME": xdgConfigHome.path,
                           "GIT_CONFIG_GLOBAL": globalConfig.path, "GIT_CONFIG_NOSYSTEM": "1",
                           "GIT_TEST_MAINT_AUTO_DETACH": "false"]
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    /// A sandbox that lets everything through, so libgit2 is pointed at the
    /// shell's `HOME` (see `IsolatedGitHost.sandbox`).
    var sandbox: Sandbox {
        sandbox { _ in }
    }

    func sandbox(authorize: @escaping @Sendable (URL) async throws -> Void) -> Sandbox {
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        return Sandbox(
            documentsDirectory: temporary, downloadsDirectory: temporary, libraryDirectory: temporary,
            moviesDirectory: temporary, musicDirectory: temporary, picturesDirectory: temporary,
            sharedPublicDirectory: temporary, temporaryDirectory: temporary, trashDirectory: temporary,
            userDirectory: temporary, cachesDirectory: temporary, homeDirectory: home,
            authorize: authorize)
    }

    // MARK: Fixtures

    /// `git init` at `name` under the root, with one commit of `file.txt`.
    @discardableResult
    func repository(_ name: String = "repo") async throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await gitOK(["init", "-q", "-b", "main"], in: directory)
        try await gitOK(["config", "user.name", "Fixture"], in: directory)
        try await gitOK(["config", "user.email", "fixture@example.com"], in: directory)
        try Data("one\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
        try await gitOK(["add", "file.txt"], in: directory)
        try await gitOK(["commit", "-q", "-m", "one"], in: directory)
        return directory
    }

    @discardableResult
    func gitOK(
        _ arguments: [String], in directory: URL, environment extra: [String: String] = [:]
    ) async throws -> String {
        let result = try await system(arguments, in: directory, environment: extra)
        guard result.status == 0 else {
            throw Failure(description: "git \(arguments.joined(separator: " ")): \(result.stderr)")
        }
        return result.stdout
    }

    // MARK: Running

    /// System git.
    func system(
        _ arguments: [String], in directory: URL, environment extra: [String: String] = [:]
    ) async throws -> Output {
        try await process(URL(fileURLWithPath: "/usr/bin/env"), ["git"] + arguments, in: directory, environment: extra)
    }

    /// The port, through `entry`.
    func port(
        _ entry: Entry, _ arguments: [String], in directory: URL, environment extra: [String: String] = [:]
    ) async throws -> Output {
        switch entry {
        case .standalone:
            let binary = try #require(Self.standaloneBinary, "the built git executable is next to the test bundle")
            return try await process(binary, arguments, in: directory, environment: extra)
        case .embedded:
            let shell = Shell(stdout: OutputSink(), stderr: OutputSink(),
                              environment: Environment(variables: environment(extra),
                                                       workingDirectory: directory.path))
            shell.sandbox = sandbox
            return try await embedded(arguments, in: shell)
        }
    }

    /// The registered `git` command, run as a host shell runs it, in `shell`.
    func embedded(_ arguments: [String], in shell: Shell) async throws -> Output {
        let command = try #require(Self.registeredCommand, "SwiftPortsCommands registers git")
        let out = OutputSink(), err = OutputSink()
        let child = shell.copy()
        child.stdout = out
        child.stderr = err
        let status = try await child.withCurrent { try await command.run(["git"] + arguments) }
        out.finish()
        err.finish()
        return Output(stdout: await out.readAllString(), stderr: await err.readAllString(), status: status.code)
    }

    /// How long one git run may take before it is stopped and reported.
    static let processTimeLimit: Duration = .seconds(120)

    /// Runs `executable` to its end without holding a thread of the
    /// cooperative pool: each pipe is drained to EOF on a thread of its own,
    /// the exit arrives through `terminationHandler`, and the caller awaits
    /// all three. A run past ``processTimeLimit`` is terminated and fails.
    private func process(
        _ executable: URL, _ arguments: [String], in directory: URL, environment extra: [String: String]
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment(extra)
        let out = Pipe(), err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let run = ProcessRun(label: ([executable.lastPathComponent] + arguments).joined(separator: " "))
        process.terminationHandler = { run.exited($0.terminationStatus) }
        // `run()` closes the parent's write ends, so EOF comes with the child's.
        try process.run()
        run.drain(out.fileHandleForReading, stdout: true)
        run.drain(err.fileHandleForReading, stdout: false)
        let watchdog = Task {
            try await Task.sleep(for: Self.processTimeLimit)
            if process.isRunning { process.terminate() }
            run.timedOut()
        }
        defer { watchdog.cancel() }
        return try await run.result()
    }

    /// One run's pipes and exit, gathered from their threads under a lock.
    private final class ProcessRun: @unchecked Sendable {
        private let lock = NSLock()
        private let label: String
        private var stdout = Data()
        private var stderr = Data()
        private var status: Int32?
        private var pending = 3
        private var failure: Failure?
        private var continuation: CheckedContinuation<Output, Error>?

        init(label: String) {
            self.label = label
        }

        /// Reads `handle` to EOF on a dedicated thread, outside both the
        /// cooperative pool and Dispatch's.
        func drain(_ handle: FileHandle, stdout isStdout: Bool) {
            let thread = Thread { [self] in
                let data = handle.readDataToEndOfFile()
                try? handle.close()
                update {
                    if isStdout { stdout = data } else { stderr = data }
                    pending -= 1
                }
            }
            thread.name = "GitInvocationOracle pipe"
            thread.start()
        }

        func exited(_ code: Int32) {
            update {
                status = code
                pending -= 1
            }
        }

        func timedOut() {
            update {
                if pending > 0 {
                    let limit = GitInvocationOracle.processTimeLimit
                    failure = Failure(description: "git run still going after \(limit): \(label)")
                }
            }
        }

        func result() async throws -> Output {
            try await withCheckedThrowingContinuation { continuation in
                update { self.continuation = continuation }
            }
        }

        /// Changes the state, then resumes the waiter once if the run is over.
        private func update(_ change: () -> Void) {
            lock.lock()
            change()
            var resume: (CheckedContinuation<Output, Error>, Result<Output, Error>)?
            if let continuation {
                if let failure {
                    resume = (continuation, .failure(failure))
                } else if pending == 0, let status {
                    resume = (continuation, .success(Output(
                        stdout: String(decoding: stdout, as: UTF8.self),
                        stderr: String(decoding: stderr, as: UTF8.self), status: status)))
                }
                if resume != nil { self.continuation = nil }
            }
            lock.unlock()
            if let (continuation, result) = resume { continuation.resume(with: result) }
        }
    }

    // MARK: Comparing

    /// System git, then each entry path of the port, from the same state of
    /// `fixture` (copied before and put back after every run): the outputs
    /// and `state` (read with system git after each run) must be the same.
    /// `stdout: false` leaves stdout out (a version line); `entries` narrows
    /// the entry paths compared. Returns system
    /// git's output.
    @discardableResult
    func compare(
        _ arguments: [String], in directory: URL, environment extra: [String: String] = [:],
        fixture: URL? = nil, stdout compareStdout: Bool = true,
        state: (() async throws -> String)? = nil, entries: [Entry] = Entry.allCases,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> Output {
        let fixture = fixture ?? root
        let backup = fixture.deletingLastPathComponent()
            .appendingPathComponent(".backup-\(fixture.lastPathComponent)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.copyItem(at: fixture, to: backup)
        defer { try? FileManager.default.removeItem(at: backup) }
        let expected = try await system(arguments, in: directory, environment: extra)
        let expectedState = try await state?()
        for entry in entries {
            try replace(fixture, with: backup)
            let actual = try await port(entry, arguments, in: directory, environment: extra)
            let label = "\(entry) git \(arguments) in \(directory.lastPathComponent)"
            if compareStdout {
                #expect(actual.stdout == expected.stdout, "stdout, \(label)", sourceLocation: sourceLocation)
            }
            #expect(actual.stderr == expected.stderr, "stderr, \(label)", sourceLocation: sourceLocation)
            #expect(actual.status == expected.status, "status, \(label)", sourceLocation: sourceLocation)
            if let state {
                let actualState = try await state()
                #expect(actualState == expectedState, "state, \(label)", sourceLocation: sourceLocation)
            }
        }
        try replace(fixture, with: backup)
        return expected
    }

    private func replace(_ destination: URL, with backup: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: backup, to: destination)
    }

    // MARK: Version

    /// Whether system git's usage text is the one the port prints, git
    /// 2.54's (it grows with each new global option), from `git version 2.54.0`.
    func printsReferenceUsage() async throws -> Bool {
        let version = try await system(["--version"], in: root)
        let words = version.stdout.split(separator: " ")
        guard version.status == 0, words.count >= 3 else { return false }
        return words[2].split(separator: ".").prefix(2).compactMap { Int($0) } == [2, 54]
    }

    /// Whether system git is at least `major.minor`: what a condition git
    /// learned later (`hasconfig:` in 2.36) or a decision it changed reads as
    /// on an older one (Linux CI's 2.34) is no parity to compare against.
    func systemGitIsAtLeast(_ major: Int, _ minor: Int) async throws -> Bool {
        let version = try await system(["--version"], in: root)
        let words = version.stdout.split(separator: " ")
        guard version.status == 0, words.count >= 3 else { return false }
        let parts = words[2].split(separator: ".").prefix(2).compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        return (parts[0], parts[1]) >= (major, minor)
    }
}
#endif
