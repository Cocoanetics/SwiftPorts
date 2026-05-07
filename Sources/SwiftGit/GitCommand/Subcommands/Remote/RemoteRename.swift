import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

struct RemoteRename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a remote."
    )

    @Argument(help: "Existing remote name.")
    var oldName: String

    @Argument(help: "New remote name.")
    var newName: String

    func run() async throws {
        do {
            let problems = try await CommandContext.gitClient()
                .remoteRename(from: oldName, to: newName)
            // Real git surfaces problematic refspecs here (rare).
            for problem in problems {
                let stderr = Stdio.stderr
                stderr.write(Data(
                    "warning: could not rename refspec: \(problem)\n".utf8))
            }
        } catch let err as Libgit2Error
            where err.message.lowercased().contains("not found") {
            throw CLIError.stderr(
                "error: Could not rename config section 'remote.\(oldName)' to 'remote.\(newName)'",
                exitCode: 1)
        }
    }
}
