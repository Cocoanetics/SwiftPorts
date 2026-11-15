#if !os(Android)
import Foundation
import ShellKit

/// Test-only shell dispatcher: an unresolved name falls through to a denying launcher.
struct RegisteredCommandLauncher: ProcessLauncher {
    func launch(
        _ executable: Executable, arguments: Arguments, environment: Environment,
        workingDirectory: String?, input: InputSource, output: OutputSink, error: OutputSink
    ) async throws -> ExecutionRecord {
        guard case .name(let name) = executable.storage, let command = Shell.current.commands[name] else {
            throw ProcessLaunchUnresolved(executable: executable)
        }
        let child = Shell.current.copy()
        child.stdin = input
        child.stdout = output
        child.stderr = error
        child.environment = environment
        if let workingDirectory { child.environment.workingDirectory = workingDirectory }
        let status = try await child.withCurrent { try await command.run([name] + arguments.values) }
        return ExecutionRecord(processIdentifier: 0, terminationStatus: .exited(status.code))
    }
}
#endif
