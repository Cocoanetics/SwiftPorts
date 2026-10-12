import Foundation
import ShellKit
import SSHKit

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

        // Interactive shell and PTY channels are deliberately Phase 3 (#115).
        // This target is the Phase-1 non-interactive `ssh host command` face.
        guard !arguments.command.isEmpty else {
            stderr.write(SSHArgumentsParser.usage)
            return 255
        }

        var client: SSHClient?
        do {
            let config: SSHConfig
            if arguments.configFile == "none" {
                config = SSHConfig.parse(
                    arguments.configurationDirectives.joined(separator: "\n"),
                    source: "command-line")
            } else {
                config = try await SSHConfig.load(
                    path: arguments.configFile,
                    commandLineOptions: arguments.configurationDirectives)
            }
            let hostConfig = try config.resolve(host: arguments.host)
            let identities = try await IdentityLoader.loadAvailable(paths: hostConfig.identityFiles)
            let knownHosts = try await KnownHostsStore.load(paths: hostConfig.userKnownHostsFile)

            let connected = try await SSHClient.connect(
                host: hostConfig.hostName,
                port: hostConfig.port,
                username: hostConfig.user ?? Shell.current.hostInfo.userName,
                identities: identities,
                knownHosts: knownHosts,
                userKnownHostsFilePath: hostConfig.userKnownHostsFile.first,
                strictHostKeyChecking: hostConfig.strictHostKeyChecking)
            client = connected

            let channel = try await connected.exec(arguments.command.joined(separator: " "))
            let status = try await relay(
                channel: channel,
                stdin: stdin,
                stdout: stdout,
                stderr: stderr)
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

    private static func relay(
        channel: SSHExecChannel,
        stdin: InputSource,
        stdout: OutputSink,
        stderr: OutputSink
    ) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32?.self) { group in
            group.addTask {
                do {
                    for await data in stdin.bytes {
                        try Task.checkCancellation()
                        try await channel.write(Array(data))
                    }
                    try await channel.closeStdin()
                } catch is CancellationError {
                    // The remote command exited before local stdin did.
                } catch {
                    if !Task.isCancelled { throw error }
                }
                return nil
            }
            group.addTask {
                for await bytes in channel.stdout {
                    stdout.write(Data(bytes))
                }
                return nil
            }
            group.addTask {
                for await bytes in channel.stderr {
                    stderr.write(Data(bytes))
                }
                return nil
            }
            group.addTask {
                let status = try await channel.exitStatus
                try await channel.waitUntilClosed()
                return status
            }

            var exitStatus: Int32?
            for try await result in group {
                if let result {
                    exitStatus = result
                    group.cancelAll()
                }
            }
            return exitStatus ?? 255
        }
    }
}
