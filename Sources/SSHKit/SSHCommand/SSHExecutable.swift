import Foundation
import ForgeKit
import NIOSSH
import ShellKit
import SSHKit
#if canImport(Dispatch)
import Dispatch
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

public enum SSHExecutable {
    @discardableResult
    public static func run(
        argv: [String],
        stdin: InputSource,
        stdout: OutputSink,
        stderr: OutputSink
    ) async -> Int32 {
        let arguments: SSHArguments
        do {
            arguments = try SSHArgumentsParser.parse(argv)
        } catch let error as SSHArgumentError {
            if let diagnostic = error.diagnostic {
                stderr.write(diagnostic)
            }
            if case .badPort = error {
                return 255
            }
            stderr.write(SSHArgumentsParser.usage)
            return 255
        } catch {
            stderr.write("ssh: \(error)\n")
            return 255
        }

        let ttyFlag = Self.shouldAllocatePseudoTerminal(for: arguments, stderr: stderr)

        var client: SSHClient?
        do {
            let config: SSHConfig
            if arguments.configFile.caseInsensitiveCompare("none") == .orderedSame {
                config = SSHConfig.parse(
                    arguments.configurationDirectives.joined(separator: "\n"),
                    source: "command-line")
            } else {
                config = try await SSHConfig.load(
                    path: arguments.configFile,
                    commandLineOptions: arguments.configurationDirectives,
                    requireFile: arguments.configFileWasSpecified)
            }
            let hostConfig = try config.resolve(host: arguments.host)
            let knownHosts = try await KnownHostsStore.load(paths: hostConfig.userKnownHostsFile)

            // Identity files are decrypted lazily by `SSHClient` itself, one at a time, only once
            // authentication actually needs the next one — never before host-key verification (or
            // even the TCP connection) succeeds, and never for an identity past the one that
            // authenticates (issue #115), matching `ssh(1)`'s own `pubkey_prepare`/`userauth_pubkey`
            // timing (`sshconnect2.c`).
            let connected = try await SSHClient.connect(
                host: hostConfig.hostName,
                port: hostConfig.port,
                username: hostConfig.user ?? Shell.current.hostInfo.userName,
                identityFiles: hostConfig.identityFiles,
                knownHosts: knownHosts,
                userKnownHostsFilePath: hostConfig.userKnownHostsFile.first,
                strictHostKeyChecking: hostConfig.strictHostKeyChecking)
            client = connected

            let pseudoTerminal = ttyFlag ? Self.pseudoTerminalRequest() : nil
            let pseudoTerminalRequired = arguments.requestTTY == .yes || arguments.requestTTY == .force

            let channel: SSHExecChannel
            do {
                if arguments.command.isEmpty {
                    channel = try await connected.shell(pseudoTerminal: pseudoTerminal, pseudoTerminalRequired: pseudoTerminalRequired)
                } else {
                    channel = try await connected.exec(
                        arguments.command.joined(separator: " "),
                        pseudoTerminal: pseudoTerminal,
                        pseudoTerminalRequired: pseudoTerminalRequired)
                }
            } catch SSHClientChannelError.pseudoTerminalRequestFailed {
                // Only reachable when `pseudoTerminalRequired` — an explicit `-t`/`-tt` — matching
                // `client_status_confirm` elevating `CONFIRM_TTY` to `CONFIRM_CLOSE` and the whole
                // connection being `fatal()`'d (`clientloop.c`).
                try? await connected.close()
                stderr.write("PTY allocation request failed on channel 0\r\n")
                return 255
            }

            let status = try await relay(channel: channel, stdin: stdin, stdout: stdout, stderr: stderr)
            try? await connected.close()
            return status
        } catch let error as SSHError {
            if let client { try? await client.close() }
            stderr.write("\(error.description)\n")
            return 255
        } catch {
            if let client { try? await client.close() }
            stderr.write("ssh: \(error)\n")
            return 255
        }
    }

    /// `ssh.c`'s `tty_flag` derivation (lines ~1378-1398): starts from `-t`/`-T`
    /// (`arguments.requestTTY`), defaults to "allocate when no command was given" (a login shell),
    /// is forced off by `-T`, and is finally vetoed unless stdin is a real terminal — *unless*
    /// `-tt` (`.force`) said to allocate one regardless.
    private static func shouldAllocatePseudoTerminal(for arguments: SSHArguments, stderr: OutputSink) -> Bool {
        var ttyFlag: Bool
        switch arguments.requestTTY {
        case .yes, .force:
            ttyFlag = true
        case .auto, .no:
            ttyFlag = false
        }

        // "Allocate a tty by default if no command specified."
        if arguments.command.isEmpty {
            ttyFlag = arguments.requestTTY != .no
        }

        if arguments.requestTTY == .no {
            ttyFlag = false
        }

        if !TTY.isStdinTTY, arguments.requestTTY != .force {
            if ttyFlag {
                // `logit(...)` to stderr (`clientloop.c`/`ssh.c`), the exact wording and CRLF
                // OpenSSH uses even outside raw mode.
                stderr.write("Pseudo-terminal will not be allocated because stdin is not a terminal.\r\n")
            }
            ttyFlag = false
        }

        return ttyFlag
    }

    #if os(Windows)
    private static func pseudoTerminalRequest() -> SSHChannelRequestEvent.PseudoTerminalRequest? {
        // No termios/ioctl on Windows to build one from, and `SSHClient.connect` already traps
        // there before any of this runs (Docs/SSH.md's Phase 0 findings) — never reachable in
        // practice, just needs to compile.
        nil
    }
    #else
    private static func pseudoTerminalRequest() -> SSHChannelRequestEvent.PseudoTerminalRequest? {
        SSHLocalTerminal.pseudoTerminalRequest()
    }
    #endif

    private static func relay(
        channel: SSHExecChannel,
        stdin: InputSource,
        stdout: OutputSink,
        stderr: OutputSink
    ) async throws -> Int32 {
        #if os(Windows)
        return try await Self.relayChannel(channel: channel, stdin: stdin, stdout: stdout, stderr: stderr)
        #else
        guard channel.hasPseudoTerminal, let savedTerminal = SSHLocalTerminal.enterRawMode() else {
            return try await Self.relayChannel(channel: channel, stdin: stdin, stdout: stdout, stderr: stderr)
        }
        defer { SSHLocalTerminal.leaveRawMode(savedTerminal) }

        // A dedicated queue, not `.main`: this code also runs embedded in other hosts (e.g. a
        // SwiftBash builtin) whose main entry point may never drain `DispatchQueue.main`.
        SIGWINCHDisposition.acquire()
        let windowChangeSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: DispatchQueue(label: "SSHExecutable.windowChange"))
        windowChangeSource.setEventHandler {
            guard let size = SSHLocalTerminal.windowSize() else { return }
            Task {
                try? await channel.sendWindowChange(columns: size.columns, rows: size.rows, pixelWidth: size.pixelWidth, pixelHeight: size.pixelHeight)
            }
        }
        windowChangeSource.resume()
        defer {
            windowChangeSource.cancel()
            SIGWINCHDisposition.release()
        }

        return try await Self.relayChannel(channel: channel, stdin: stdin, stdout: stdout, stderr: stderr)
        #endif
    }

    private static func relayChannel(
        channel: SSHExecChannel,
        stdin: InputSource,
        stdout: OutputSink,
        stderr: OutputSink
    ) async throws -> Int32 {
        let inputTask = Task {
            for await data in stdin.bytes {
                try Task.checkCancellation()
                try await channel.write(Array(data))
            }
            try await channel.closeStdin()
        }
        async let stdoutRelay: Void = {
            for await bytes in channel.stdout {
                stdout.write(Data(bytes))
            }
        }()
        async let stderrRelay: Void = {
            for await bytes in channel.stderr {
                stderr.write(Data(bytes))
            }
        }()

        do {
            let status = try await channel.exitStatus
            try await channel.waitUntilClosed()

            // A remote command may exit while process stdin remains open (the
            // common terminal case). Stop only that relay; stdout/stderr must
            // drain their already-buffered final chunks before returning.
            inputTask.cancel()
            do {
                try await inputTask.value
            } catch is CancellationError {
                // Expected when the peer exits before local stdin closes.
            } catch {
                if !inputTask.isCancelled { throw error }
            }
            _ = await (stdoutRelay, stderrRelay)
            return status
        } catch {
            inputTask.cancel()
            _ = try? await inputTask.value
            _ = await (stdoutRelay, stderrRelay)
            throw error
        }
    }
}

#if !os(Windows)
/// Process-wide reference count for the temporary `SIGWINCH` disposition an interactive session
/// installs around its `DispatchSource.makeSignalSource` (the standard GCD idiom: `signal(2)`'s
/// disposition must not be `SIG_DFL` for a dispatch signal source to behave). `signal(2)`'s
/// disposition is process-global, so two overlapping interactive sessions in the same process
/// (e.g. two SwiftBash `ssh -t` builtins running concurrently) must not let the first session's
/// cleanup clobber the second session's still-active dispatch source — and whichever session
/// finishes last must restore whatever disposition actually existed before the *first* of them
/// ever touched it, not an unconditional `SIG_DFL`.
private enum SIGWINCHDisposition {
    private static let lock = NSLock()
    // Guarded exclusively by `lock` above, acquired/released only inside `acquire()`/`release()`.
    nonisolated(unsafe) private static var activeSessions = 0
    nonisolated(unsafe) private static var previousHandler: (@convention(c) (Int32) -> Void)?

    /// Call before installing a `DispatchSourceSignal` for `SIGWINCH`.
    static func acquire() {
        lock.lock()
        defer { lock.unlock() }
        if activeSessions == 0 {
            previousHandler = signal(SIGWINCH, SIG_IGN)
        }
        activeSessions += 1
    }

    /// Call after tearing down a `DispatchSourceSignal` for `SIGWINCH`.
    static func release() {
        lock.lock()
        defer { lock.unlock() }
        activeSessions -= 1
        if activeSessions == 0 {
            signal(SIGWINCH, previousHandler)
            previousHandler = nil
        }
    }
}
#endif
