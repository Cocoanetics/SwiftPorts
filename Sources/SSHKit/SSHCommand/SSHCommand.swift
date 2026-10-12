import ArgumentParser
import ShellKit

public struct SSHCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "OpenSSH remote login client")

    @Argument(parsing: .captureForPassthrough, help: "OPTIONS, destination, command...")
    public var rawArgv: [String] = []

    public init() {}

    public func run() async throws {
        let exit = await SSHExecutable.run(
            argv: rawArgv,
            stdin: Shell.current.stdin,
            stdout: Shell.current.stdout,
            stderr: Shell.current.stderr)
        if exit != 0 {
            throw ExitCode(exit)
        }
    }
}
