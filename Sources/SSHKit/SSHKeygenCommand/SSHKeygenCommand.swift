import ArgumentParser
import ShellKit

public struct SSHKeygenCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ssh-keygen", abstract: "OpenSSH key generation and SSH signatures")

    @Argument(parsing: .captureForPassthrough)
    public var rawArgv: [String] = []

    public init() {}

    public func run() async throws {
        let code = await SSHKeygenExecutable.run(
            argv: rawArgv, stdin: Shell.current.stdin,
            stdout: Shell.current.stdout, stderr: Shell.current.stderr)
        if code != 0 { throw ExitCode(code) }
    }
}
